//! Go to Folder (Shift+Cmd+G): a small dialog with a path field. Return or Go opens the folder
//! in the focused tab ("~" is Home); a folder that can't be opened raises the usual banner.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const style = @import("style.zig");

pub const State = struct {
    open: bool = false,
    buf: ui.TextBuffer = .{},

    pub fn deinit(self: *State) void {
        self.buf.deinit();
    }
};

/// Opens the dialog, the field holding the folder shown (all selected).
pub fn open(m: *Model) void {
    const s = &m.goto;
    s.buf.set(m.focusedTab().path());
    s.buf.want_caret = null;
    s.buf.want_selection = .{ 0, s.buf.text().len };
    s.buf.focus();
    s.open = true;
}

/// "~" and "~/x" are Home's; anything else is as typed (trimmed). In frame memory.
pub fn expand(c: *ui.Context, home: []const u8, typed: []const u8) []const u8 {
    const t = std.mem.trim(u8, typed, " \t\r\n");
    if (std.mem.eql(u8, t, "~")) return home;
    if (std.mem.startsWith(u8, t, "~/")) return std.fs.path.join(c.alloc(), &.{ home, t[2..] }) catch t;
    return t;
}

pub fn view(c: *ui.Context, m: *Model) void {
    const s = &m.goto;
    const d = kit.dialog(c, "goto", &s.open, .{ .title = "Go to Folder", .description = "Type a folder's path.", .ok = "Go", .width = 460 }) orelse return;
    const r = ui.textField(c, &s.buf, .{ .width = .fill, .placeholder = "/Users/you/Documents", .size = 13.5 });
    const result = d.end();
    if (result == .ok or r.submitted) {
        s.open = false;
        const path = expand(c, m.home, s.buf.text());
        if (path.len > 0) style.post(c, m, .{ .open = path });
    }
}
