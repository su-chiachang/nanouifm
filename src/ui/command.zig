//! One command: what the keyboard, the context menu, the toolbar's menus, the command palette and
//! (next) the menu bar all run. The table of them is `commands.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const ids = @import("command_id.zig");

pub const Id = ids.Id;
pub const Category = ids.Category;

/// A question about the model: whether a command applies, or is ticked.
pub const Pred = *const fn (*Model) bool;

pub const Command = struct {
    id: Id,
    /// The menu and palette title (`dynamic_title` replaces it where the wording follows state).
    title: []const u8,
    category: Category,
    /// The key that runs it; null for commands that only a menu or the palette run.
    shortcut: ?ui.Shortcut = null,
    /// An SF Symbol for menus and the palette.
    symbol: []const u8 = "",
    /// Acts on files: off while a text field has the keyboard, so ⌘Z, ⌘⌫, Return and the arrows
    /// edit text instead.
    file_scope: bool = false,
    /// False for a second key of another command (Cmd+Down is Open's twin).
    in_palette: bool = true,
    /// False for a second key of another command: the menu bar lists the command once, and the
    /// twin's key stays with the view's dispatcher (see `menu_link.zig`).
    in_menu: bool = true,
    /// Whether running it would do something right now; null: always.
    enabled: ?Pred = null,
    /// Whether its menu item carries a check mark; null: not a toggle.
    checked: ?Pred = null,
    /// The title right now ("Undo Rename"), written into `buf`.
    dynamic_title: ?*const fn (*Model, buf: []u8) []const u8 = null,
    /// The action itself. Runs from `Model.applyPending`, never mid-frame.
    run: *const fn (*Model) std.mem.Allocator.Error!void,
};
