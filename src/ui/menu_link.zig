//! What the model knows of the native menu bar (`menu_bar.zig`, installed by main.zig only; in
//! tests it stays empty, so the in-view shortcuts own every key as before).
//!
//! WHO OWNS A KEY. A command's accelerator is in the menu when `ownsKey` says so (a shortcut with
//! Cmd or Ctrl, on a command that is in the menu). With the menu installed, AppKit offers such a
//! key to the menu bar before the view ever sees it (the view's `performKeyEquivalent:` passes it
//! on), so exactly one of the two takes it:
//!   - the MENU takes it while its item is enabled (`State.owns`: the view's dispatcher,
//!     `command_keys.zig`, skips the command), and
//!   - the VIEW's dispatcher takes it when the item is disabled in the menu (AppKit skips a
//!     disabled item) but the command applies, and whenever a text field has the keyboard: the
//!     view then holds the menu's key equivalents back (`ui.suspendMenuKeyEquivalents`) so ⌘C, ⌘A,
//!     ⌘Z and ⌘⌫ edit text.
//! Keys that are not menu accelerators (Return for Rename, ⌘↓'s twin of Open, Ctrl+Tab) stay with the view.
const std = @import("std");
const nanoui = @import("nanoui");
const Command = @import("command.zig").Command;
const Id = @import("command.zig").Id;

pub const count = std.enums.values(Id).len;

/// Whether this command's key is an accelerator of its menu item: a Cmd or Ctrl chord of a command
/// the menu lists. Ctrl+Tab is left to the view (AppKit's key-view loop claims it too).
pub fn ownsKey(cmd: *const Command) bool {
    const s = cmd.shortcut orelse return false;
    // Tab chords and Cmd+Backspace stay with the view: nanoui's "Backspace" accelerator may not match
    // AppKit's Delete key, which would silently kill Move to Trash. One owner per key, never both.
    const S = nanoui.ui.Shortcut;
    return cmd.in_menu and (s.cmd or s.ctrl) and s.key != S.tab and s.key != S.backspace;
}

pub const State = struct {
    /// A menu bar is installed (main.zig).
    installed: bool = false,
    /// Which items the menu bar shows enabled, as of its last refresh.
    enabled: std.StaticBitSet(count) = .empty,
    /// Brings the menu bar's items (titles, enabled, checked) up to date with the model.
    sync: ?*const fn (ctx: *anyopaque) void = null,
    ctx: ?*anyopaque = null,

    /// The menu takes `cmd`'s key now (see the file's comment).
    pub fn owns(self: *const State, cmd: *const Command) bool {
        return self.installed and ownsKey(cmd) and self.enabled.isSet(@backingInt(cmd.id));
    }

    pub fn refresh(self: *State) void {
        if (self.sync) |f| f(self.ctx.?);
    }
};
