//! Drag and drop in the sidebar, over nanoui's in-window drag (`dragSource` / `dropTarget`; the
//! payload says what is dragged, see `drag_kind.zig`):
//!   - an entry of Favorites or Pinned dragged over a row of either: it lands before or after that
//!     row (the upper or the lower half), over a section's header: at its top. Reordering, and
//!     moving between the two sections.
//!   - the rows of a pane dragged over the Favorites or Pinned header: the selected FOLDERS are added
//!     there (at the end). Over a folder row they are moved into it (`drops.zig`).
//! A `dropTarget` answers once per drag, so each row and header asks exactly once, here, and
//! reads the kind of what landed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const sidebar_model = @import("sidebar_model.zig");
const drag_kind = @import("drag_kind.zig");
const drops = @import("drops.zig");
const target = @import("file_target.zig");
const style = @import("style.zig");

/// What a row or header should draw while a drag is over it.
pub const Over = enum { none, files, before, after, header };

/// Entries can be dragged from, and dropped into, Favorites and Pinned.
pub fn reorderable(section: usize) bool {
    return section == @backingInt(sidebar_model.SectionKind.favorites) or section == @backingInt(sidebar_model.SectionKind.pinned);
}

fn kindOf(section: usize) sidebar_model.SectionKind {
    return @fromBackingInt(@intCast(section));
}

fn move(c: *ui.Context, m: *Model, e: drag_kind.Entry, section: usize, to: usize) void {
    if (e.section >= m.sidebar.sections.len) return;
    const rows = m.sidebar.sections[e.section].rows.items;
    if (e.row >= rows.len) return;
    const id = rows[e.row].id orelse return;
    style.post(c, m, .{ .sidebar_move = .{ .id = id, .kind = kindOf(section), .to = @intCast(to) } });
}

fn upperHalf(c: *ui.Context, r: ui.Rect) bool {
    return c.input.mouse.y < r.y + r.h / 2;
}

/// Row `ri` of section `si`, whose folder is `path`, as a drop target (`rect`: where it was drawn
/// last frame). Queues what landed; says what to draw for a drag that is over.
pub fn onRow(c: *ui.Context, m: *Model, si: usize, ri: usize, rect: ?ui.Rect, path: []const u8) Over {
    const r = rect orelse return .none;
    var over: Over = .none;
    if (ui.dragOver(c, r)) |p| {
        if (drag_kind.asEntry(p) != null) {
            if (reorderable(si)) over = if (upperHalf(c, r)) .before else .after;
        } else if (m.view_state.file_drag != null) over = .files;
    }
    const payload = ui.dropTarget(c, r) orelse return over;
    if (drag_kind.asEntry(payload)) |e| {
        if (reorderable(si)) move(c, m, e, si, if (upperHalf(c, r)) ri else ri + 1);
    } else drops.dropFiles(c, m, payload, path);
    return .none;
}

/// The header of section `si` as a drop target (Favorites and Pinned only).
pub fn onHeader(c: *ui.Context, m: *Model, si: usize, rect: ?ui.Rect) Over {
    if (!reorderable(si)) return .none;
    const r = rect orelse return .none;
    var over: Over = .none;
    if (ui.dragOver(c, r)) |p| {
        if (drag_kind.asEntry(p) != null or (m.view_state.file_drag != null and drag_kind.asPane(p) != null)) over = .header;
    }
    const payload = ui.dropTarget(c, r) orelse return over;
    if (drag_kind.asEntry(payload)) |e| {
        move(c, m, e, si, 0);
    } else if (drag_kind.asPane(payload)) |pane_id| {
        const pi = m.paneIndex(pane_id) orelse return .none;
        const folders = target.selectedFolders(c.alloc(), &m.panes.items[pi]) catch return .none;
        for (folders) |f| style.post(c, m, .{ .sidebar_add = .{ .path = f, .kind = kindOf(si) } });
    }
    return .none;
}

/// The title of the entry being dragged, beside the pointer (called once, last).
pub fn ghost(c: *ui.Context, m: *Model) void {
    const a = ui.dragging(c) orelse return;
    const e = drag_kind.asEntry(a.payload) orelse return;
    if (e.section >= m.sidebar.sections.len or e.row >= m.sidebar.sections[e.section].rows.items.len) return;
    const th = c.theme;
    ui.key(c, "entry-drag-ghost");
    const g = ui.div(c).fixed().offset(a.point.x + 14, a.point.y + 14).layer(40).px(10).py(5).rounded(8).bg(th.accent);
    defer g.end();
    ui.text(c, m.sidebar.sections[e.section].rows.items[e.row].title, .{ .size = 12, .weight = .medium, .color = th.accent_text });
}
