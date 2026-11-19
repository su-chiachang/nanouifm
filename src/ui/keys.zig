//! The keyboard the panes answer to, read at the top of each pass (before any widget could take
//! Return or Space): arrows, Home and End (Shift extends), Return and Cmd+Down (open), Cmd+1 /
//! Cmd+2 (list / column view) and type-to-select. With no text field focused the platform offers
//! every key to the view as a shortcut, bare letters included; each is queued as an `Action` on
//! the model, which routes it by the focused pane's view mode.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const NavKey = @import("nav_key.zig").NavKey;
const typeahead = @import("typeahead.zig");

const S = ui.Shortcut;

const nav_keys = [_]struct { key: u21, nav: NavKey }{
    .{ .key = S.up, .nav = .up },
    .{ .key = S.down, .nav = .down },
    .{ .key = S.left, .nav = .left },
    .{ .key = S.right, .nav = .right },
    .{ .key = S.home, .nav = .home },
    .{ .key = S.end, .nav = .end },
};

pub fn view(c: *ui.Context, m: *Model) void {
    if (c.shortcut(.{ .key = '1', .cmd = true })) m.queue(.{ .set_view_mode = .list }) catch {};
    if (c.shortcut(.{ .key = '2', .cmd = true })) m.queue(.{ .set_view_mode = .column }) catch {};
    if (c.shortcut(.{ .key = S.down, .cmd = true })) m.queue(.open_selection) catch {};
    if (c.focus_is_text) return; // typing goes to the field
    for (nav_keys) |n| {
        if (c.shortcut(.{ .key = n.key })) m.queue(.{ .nav = .{ .key = n.nav, .shift = false } }) catch {};
        if (c.shortcut(.{ .key = n.key, .shift = true })) m.queue(.{ .nav = .{ .key = n.nav, .shift = true } }) catch {};
    }
    if (c.shortcut(.{ .key = S.enter })) m.queue(.open_selection) catch {};
    // Any other bare key is type-to-select (Shift only changes the case, which is ignored).
    if (c.input.shortcut) |s| {
        if (s.cmd or s.ctrl or s.alt or !typeahead.isTypeable(s.key)) return;
        c.input.shortcut = null;
        c.shortcut_taken = true;
        c.changed = true;
        m.queue(.{ .type_select = .{ .key = s.key, .time = c.time } }) catch {};
    }
}
