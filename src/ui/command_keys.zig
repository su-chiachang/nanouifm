//! The keyboard side of the registry: each command's shortcut, offered to the view at the top of
//! the pass (with a menu bar installed, `menu_link.zig` says which keys are the menu's). A command that acts on files is left alone while a text field has the keyboard (the
//! rename field, the Go to Folder field), and one that doesn't apply right now doesn't take its key.
//! A taken key queues `Action.run_command`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const commands = @import("commands.zig");
const hooks = @import("hooks.zig");

pub fn view(c: *ui.Context, m: *Model) void {
    const key = (c.input.shortcut orelse return).native(); // most frames carry no key at all
    if (m.menu.installed and c.focus_is_text) appKeys(c, m);
    for (&commands.all) |*cmd| {
        const s = cmd.shortcut orelse continue;
        if (!sameKey(key, s.native())) continue;
        if (m.menu.owns(cmd) and !c.focus_is_text) continue; // the menu bar takes it (menu_link.zig)
        if (cmd.file_scope and c.focus_is_text) continue;
        if (!commands.isEnabled(m, cmd)) continue;
        if (m.view_state.palette.open and cmd.id != .palette_show) return; // the palette is modal
        if (c.shortcut(s)) {
            m.queue(.{ .run_command = cmd.id }) catch {};
            c.changed = true;
        }
        return;
    }
}

/// The menu bar's own chords (the App and Window menus' roles) are held back with the rest while
/// a text field has the keyboard, so the view does them: Quit, Hide, Hide Others, Minimize.
fn appKeys(c: *ui.Context, m: *Model) void {
    const run = m.hooks.app_role orelse return;
    const chords = [_]struct { s: ui.Shortcut, role: hooks.AppRole }{
        .{ .s = .{ .key = 'q', .cmd = true }, .role = .quit },
        .{ .s = .{ .key = 'h', .cmd = true }, .role = .hide },
        .{ .s = .{ .key = 'h', .cmd = true, .alt = true }, .role = .hide_others },
        .{ .s = .{ .key = 'm', .cmd = true }, .role = .minimize },
    };
    for (chords) |ch| if (c.shortcut(ch.s)) {
        run(ch.role);
        return;
    };
}

fn sameKey(a: ui.Shortcut, b: ui.Shortcut) bool {
    return a.key == b.key and a.cmd == b.cmd and a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift;
}
