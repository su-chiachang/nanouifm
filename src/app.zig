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
const palette_view = @import("ui/palette_view.zig");
const persist = @import("ui/persist.zig");
const sidebar_menu = @import("ui/sidebar_menu.zig");
const sidebar_dnd = @import("ui/sidebar_dnd.zig");
const quick_look = @import("ui/quick_look.zig");

pub const State = model.Model;
pub const Config = model.Config;
pub const Item = model.Item;

pub fn view(m: *State, c: *ui.Context) void {
    // Last pass's clicks and keys change the folder, the order or the hidden files first, so
    // nothing the previous pass handed to the frame is freed while this one builds.
    m.watch.setWaker(c.waker);
    m.view_state.palette.index.setWaker(c.waker);
    m.vol_signal.waker = c.waker;
    m.preview.thumbs.setWaker(c.waker);
    m.loader.setWaker(c.waker);
    m.waker = c.waker;
    m.clock = c.time;
    m.text_focus = c.focus_is_text;
    const applied = m.applyPending() catch false;
    if (applied) m.menu.refresh(); // the menu bar follows what the actions changed
    quick_look.sync(m); // an open Quick Look panel follows the selection
    // With a menu bar its key equivalents take the command keys; while a text field has the
    // keyboard they are held back so the field gets them (see ui/menu_link.zig).
    if (m.menu.installed) ui.suspendMenuKeyEquivalents(c.focus_is_text);
    persist.tick(m, c); // the debounced write of the state file
    c.title_bar_height = style.tab_strip_height;
    shortcuts(c, m);
    const root = ui.div(c).row().sizeFull().bg(c.theme.background);
    defer root.end();
    panes_view.view(c, m);
    sidebar.view(c, m);
    context_menu.view(c, m); // over everything
    sidebar_menu.view(c, m);
    goto.view(c, m);
    drops.ghost(c, m);
    sidebar_dnd.ghost(c, m);
    palette_view.view(c, m); // over everything
}

/// Every command's shortcut (`ui/commands.zig` has the table: Cmd+[ / ] history, Cmd+Up, Cmd+T /
/// Cmd+W tabs, Cmd+D splits, Cmd+Backspace trash, Cmd+C / V, Cmd+Z ...), then the pane keys
/// (arrows, type-to-select) in `ui/keys.zig`.
fn shortcuts(c: *ui.Context, m: *State) void {
    rename_view.keys(c, m);
    command_keys.view(c, m);
    keys.view(c, m);
}
