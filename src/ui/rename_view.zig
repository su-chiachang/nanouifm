//! The inline rename drawn: a text field in the renamed item's row, in place of its name (list
//! and column view alike), and the keys that end it. Return commits (the field reports
//! `submitted`), so does the keyboard leaving the field (a click elsewhere); Escape cancels. All
//! three queue an action, so the model changes between frames.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const rename = @import("rename.zig");
const style = @import("style.zig");

/// Escape cancels a rename wherever the keyboard is (the field may be scrolled out of sight).
/// Call at the top of the pass, before the field is drawn.
pub fn keys(c: *ui.Context, m: *Model) void {
    if (m.rename == null) return;
    var cancel = c.input.key == .escape;
    for (c.input.ops) |op| {
        if (op == .command and op.command == .cancel) cancel = true;
    }
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) cancel = true;
    if (!cancel) return;
    c.input.key = null;
    c.input.ops = &.{};
    style.post(c, m, .cancel_rename);
}

/// Whether `path`'s row (in pane `pane_id`) shows the field instead of its name.
pub fn editing(m: *const Model, pane_id: u32, path: []const u8) bool {
    const s = m.rename orelse return false;
    return s.pane == pane_id and std.mem.eql(u8, s.path, path);
}

/// The field, sized to the row's name cell.
pub fn field(c: *ui.Context, m: *Model) void {
    const s = if (m.rename) |*r| r else return;
    const th = c.theme;
    const box = ui.div(c).row().grow().minW(0).h(20).px(4).rounded(4).bg(th.background).border(th.accent).borderW(1.5).itemsCenter();
    defer box.end();
    const r = ui.textField(c, &s.buf, .{ .bare = true, .width = .fill, .size = 13 });
    if (r.focused) {
        s.focused_once = true;
    } else if (s.focused_once) {
        s.focused_once = false;
        style.post(c, m, .commit_rename); // the keyboard went elsewhere: Finder commits
    }
    if (r.submitted) style.post(c, m, .commit_rename);
}
