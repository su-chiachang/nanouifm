//! Nanofm's window content: the panes (tabs, lists, dividers) beside the sidebar, and the
//! keyboard shortcuts.
//! The view is a function of `State` (the model); clicks and keys queue `Action`s on it, which
//! it applies at the start of the next pass.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("ui/model.zig");
const sidebar = @import("ui/sidebar.zig");
const panes_view = @import("ui/panes_view.zig");
const style = @import("ui/style.zig");
const keys = @import("ui/keys.zig");

pub const State = model.Model;
pub const Config = model.Config;
pub const Item = model.Item;

pub fn view(m: *State, c: *ui.Context) void {
    // Last pass's clicks and keys change the folder, the order or the hidden files first, so
    // nothing the previous pass handed to the frame is freed while this one builds.
    _ = m.applyPending() catch false;
    c.title_bar_height = style.tab_strip_height;
    shortcuts(c, m);
    const root = ui.div(c).row().sizeFull().bg(c.theme.background);
    defer root.end();
    panes_view.view(c, m);
    sidebar.view(c, m);
}

/// Cmd+[ and Cmd+] (history), Cmd+Up (enclosing folder), Cmd+Down (open the selection),
/// Cmd+Shift+. (hidden files); Cmd+T / Cmd+W (new, close tab), Ctrl+Tab / Ctrl+Shift+Tab (cycle
/// tabs); Cmd+D / Shift+Cmd+D (split side by side / stacked), Cmd+Opt+Left / Right (move focus).
/// Arrows, Return, Cmd+1 / Cmd+2 and type-to-select are in `ui/keys.zig`.
/// The key is the unshifted character, as `Shortcut` has it.
fn shortcuts(c: *ui.Context, m: *State) void {
    if (c.shortcut(.{ .key = '[', .cmd = true })) m.queue(.back) catch {};
    if (c.shortcut(.{ .key = ']', .cmd = true })) m.queue(.forward) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.up, .cmd = true })) m.queue(.up) catch {};
    if (c.shortcut(.{ .key = '.', .cmd = true, .shift = true })) m.queue(.toggle_hidden) catch {};
    if (c.shortcut(.{ .key = 't', .cmd = true })) m.queue(.new_tab) catch {};
    if (c.shortcut(.{ .key = 'w', .cmd = true })) m.queue(.close_active_tab) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true })) m.queue(.{ .cycle_tab = 1 }) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.tab, .ctrl = true, .shift = true })) m.queue(.{ .cycle_tab = -1 }) catch {};
    if (c.shortcut(.{ .key = 'd', .cmd = true })) m.queue(.{ .split = .side_by_side }) catch {};
    if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) m.queue(.{ .split = .stacked }) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.right, .cmd = true, .alt = true })) m.queue(.{ .focus_move = 1 }) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.left, .cmd = true, .alt = true })) m.queue(.{ .focus_move = -1 }) catch {};
    keys.view(c, m);
}
