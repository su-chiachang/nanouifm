//! Nanofm's window content: the sidebar over the list pane, and the keyboard shortcuts.
//! The view is a function of `State` (the model); clicks and keys queue `Action`s on it, which
//! it applies at the start of the next pass.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const model = @import("ui/model.zig");
const sidebar = @import("ui/sidebar.zig");
const list_pane = @import("ui/list_pane.zig");
const style = @import("ui/style.zig");

pub const State = model.Model;
pub const Config = model.Config;
pub const Item = model.Item;

pub fn view(m: *State, c: *ui.Context) void {
    // Last pass's clicks and keys change the folder, the order or the hidden files first, so
    // nothing the previous pass handed to the frame is freed while this one builds.
    _ = m.applyPending() catch false;
    c.title_bar_height = style.toolbar_height;
    shortcuts(c, m);
    const root = ui.div(c).row().sizeFull().bg(c.theme.background);
    defer root.end();
    list_pane.view(c, m);
    sidebar.view(c, m);
}

/// Cmd+[ and Cmd+] (history), Cmd+Up (enclosing folder), Cmd+Down (open the selected folder),
/// Cmd+Shift+. (hidden files). The key is the unshifted character, as `Shortcut` has it.
fn shortcuts(c: *ui.Context, m: *State) void {
    if (c.shortcut(.{ .key = '[', .cmd = true })) m.queue(.back) catch {};
    if (c.shortcut(.{ .key = ']', .cmd = true })) m.queue(.forward) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.up, .cmd = true })) m.queue(.up) catch {};
    if (c.shortcut(.{ .key = '.', .cmd = true, .shift = true })) m.queue(.toggle_hidden) catch {};
    if (c.shortcut(.{ .key = ui.Shortcut.down, .cmd = true })) {
        const tab = m.focusedTab();
        if (tab.selection.count() == 1) {
            var it = tab.selection.set.keyIterator();
            if (it.next()) |k| if (tab.listing.indexOf(k.*)) |i| if (tab.listing.visible[i].is_directory) m.queue(.{ .open = k.* }) catch {};
        }
    }
}
