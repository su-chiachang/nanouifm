//! The model's side of the toolbar's name filter: applying the field's text to a pane's tabs
//! (`Action.apply_filter`, queued by the field), clearing it when the shown tab goes to another
//! folder (checked at the end of every `applyPending`), and Cmd+F's request that a pane's field
//! take the keyboard. The text itself lives in `Pane.filter` (`filter.zig`).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;

/// The field's text changed: every tab of pane `pane_id` is listed again by name.
pub fn apply(m: *Model, pane_id: u32) Allocator.Error!void {
    const i = m.paneIndex(pane_id) orelse return;
    const pane = &m.panes.items[i];
    try pane.refilter(m.show_hidden);
    if (pane.filter.isActive()) try pane.filter.mark(m.gpa, pane.tab()) else pane.filter.unmark(m.gpa);
}

/// Cmd+F: the focused pane's field takes the keyboard in the next frame (see `toolbar.zig`).
pub fn focus(m: *Model) void {
    m.view_state.focus_filter = m.focusedPane().id;
}

/// A pane whose shown tab is in another folder than the filter was applied in loses the filter
/// (the same tab went somewhere); one whose shown tab is another tab just keeps it.
pub fn syncNavigation(m: *Model) Allocator.Error!void {
    for (m.panes.items) |*p| {
        if (!p.filter.isActive()) continue;
        const t = p.tab();
        const moved = p.filter.tab == t.id and if (p.filter.path) |fp| !std.mem.eql(u8, fp, t.path()) else false;
        if (moved) {
            p.filter.buf.clear();
            p.filter.unmark(m.gpa);
            try p.refilter(m.show_hidden);
        } else if (p.filter.tab != t.id or p.filter.path == null) {
            try p.filter.mark(m.gpa, t);
        }
    }
}
