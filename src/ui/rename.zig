//! Inline rename: the item being renamed, the text field's buffer, and the three ways it ends.
//! Return (or the field losing the keyboard) commits through `FileOperationService.rename`, which
//! rejects empty names, "/" and ":" and a name already taken (the banner says why and the field
//! stays, so the name can be fixed); Escape cancels. The views draw the field in the item's row
//! (`rename_view.zig`); the model runs these from queued actions.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const target = @import("file_target.zig");
const file_actions = @import("file_actions.zig");
const refresh = @import("file_refresh.zig");

pub const Session = struct {
    /// The pane whose row shows the field.
    pane: u32,
    /// The item being renamed (owned).
    path: []u8,
    buf: ui.TextBuffer = .{},
    /// The field has held the keyboard: from then on losing it commits.
    focused_once: bool = false,

    pub fn deinit(self: *Session, gpa: Allocator) void {
        gpa.free(self.path);
        self.buf.deinit();
        self.* = undefined;
    }
};

/// Where the name ends and the extension starts: the part Finder selects first.
pub fn stemEnd(name: []const u8, is_directory: bool) usize {
    if (is_directory) return name.len;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name.len;
    return if (dot == 0) name.len else dot;
}

pub fn isRenaming(m: *const Model, path: []const u8) bool {
    const s = m.rename orelse return false;
    return std.mem.eql(u8, s.path, path);
}

/// Starts renaming the item at `path`, in pane `pane_id`'s rows; the name is selected up to its
/// extension. A rename in progress is dropped.
pub fn beginAt(m: *Model, pane_id: u32, path: []const u8, is_directory: bool) Allocator.Error!void {
    cancel(m);
    const copy = try m.gpa.dupe(u8, path);
    errdefer m.gpa.free(copy);
    var s: Session = .{ .pane = pane_id, .path = copy };
    errdefer s.buf.deinit();
    const name = std.fs.path.basename(path);
    s.buf.set(name);
    s.buf.want_caret = null;
    s.buf.want_selection = .{ 0, stemEnd(name, is_directory) };
    s.buf.focus();
    m.rename = s;
}

/// Return on a single selected item (the Rename command).
pub fn begin(m: *Model) Allocator.Error!void {
    const item = target.single(m.focusedPane()) orelse return;
    try beginAt(m, m.focusedPane().id, item.path, item.is_directory);
}

pub fn cancel(m: *Model) void {
    if (m.rename) |*s| s.deinit(m.gpa);
    m.rename = null;
}

/// Applies the edit. A refusal raises the banner and leaves the field open.
pub fn commit(m: *Model) Allocator.Error!void {
    const s = if (m.rename) |*p| p else return;
    const old = try m.gpa.dupe(u8, s.path);
    defer m.gpa.free(old);
    const pane_id = s.pane;
    const new_path = m.ops.rename(old, s.buf.text()) catch |e| {
        s.focused_once = false;
        return file_actions.reportFailure(m, e);
    };
    defer m.gpa.free(new_path);
    cancel(m);
    m.clearNotice();
    try refresh.parents(m, &.{ old, new_path });
    // The renamed item stays selected, unless a click since moved the selection elsewhere.
    const i = m.paneIndex(pane_id) orelse return;
    const pane = &m.panes.items[i];
    if (target.count(pane) == 0 or target.shown(pane).sel.contains(old)) try refresh.select(m, i, &.{new_path});
}

/// Drops a rename whose row is gone (its pane or tab closed, its folder left): nothing would draw
/// the field, and the edit would wait forever. Called after each batch of actions.
pub fn validate(m: *Model) void {
    const s = m.rename orelse return;
    const i = m.paneIndex(s.pane) orelse return cancel(m);
    const pane = &m.panes.items[i];
    const tab = pane.tab();
    const present = switch (pane.view_mode) {
        .list => tab.exp.indexOf(s.path) != null,
        .column => for (tab.col.columns.items) |c| {
            if (c.listing.indexOf(s.path) != null) break true;
        } else false,
    };
    if (!present) cancel(m);
}
