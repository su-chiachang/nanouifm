//! Nanofm's window content: the panes (tabs, lists, dividers) beside the sidebar, the context
//! menu and dialogs over them, and the keyboard shortcuts (through the command registry).
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
const command_keys = @import("ui/command_keys.zig");
const rename_view = @import("ui/rename_view.zig");
const goto = @import("ui/goto.zig");
const context_menu = @import("ui/context_menu.zig");
const drops = @import("ui/drops.zig");

pub const State = model.Model;
pub const Config = model.Config;
pub const Item = model.Item;

pub fn view(m: *State, c: *ui.Context) void {
    // Last pass's clicks and keys change the folder, the order or the hidden files first, so
    // nothing the previous pass handed to the frame is freed while this one builds.
    m.watch.setWaker(c.waker);
    _ = m.applyPending() catch false;
    c.title_bar_height = style.tab_strip_height;
    shortcuts(c, m);
    const root = ui.div(c).row().sizeFull().bg(c.theme.background);
    defer root.end();
    panes_view.view(c, m);
    sidebar.view(c, m);
    context_menu.view(c, m); // over everything
    goto.view(c, m);
    drops.ghost(c, m);
}

/// Every command's shortcut (`ui/commands.zig` has the table: Cmd+[ / ] history, Cmd+Up, Cmd+T /
/// Cmd+W tabs, Cmd+D splits, Cmd+Backspace trash, Cmd+C / V, Cmd+Z ...), then the pane keys
/// (arrows, type-to-select) in `ui/keys.zig`.
fn shortcuts(c: *ui.Context, m: *State) void {
    rename_view.keys(c, m);
    command_keys.view(c, m);
    keys.view(c, m);
}
