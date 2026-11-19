//! The toolbar's two popover menus, drawn with the context menu's own rows (`context_menu.rows`):
//! Sort (key, direction, folders first) and the "..." menu (view mode, hidden files, splits, the
//! palette). One is open at a time, hanging from the button of the pane that opened it; every
//! line is a registry command, so titles, check marks and shortcut labels come from there and
//! choosing one queues `Action.run_command` (after focusing the pane, whose state the check marks
//! show).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const Model = @import("model.zig").Model;
const pane_sizes = @import("pane_sizes.zig");
const context_menu = @import("context_menu.zig");
const style = @import("style.zig");

const Line = context_menu.Line;
const sep = context_menu.sep;

pub const Kind = enum { sort, more };

pub const State = struct {
    open: bool = false,
    kind: Kind = .sort,
    /// The pane whose button opened it.
    pane: u32 = 0,
    /// That button (window points), where the popover hangs.
    anchor: ?pane_sizes.Rect = null,
};

const sort_lines = [_]Line{
    .{ .id = .sort_name, .label = "Name" },
    .{ .id = .sort_kind, .label = "Kind" },
    .{ .id = .sort_size, .label = "Size" },
    .{ .id = .sort_modified, .label = "Date Modified" },
    .{ .id = .sort_created, .label = "Date Created" },
    sep,
    .{ .id = .sort_ascending, .label = "Ascending" },
    .{ .id = .sort_descending, .label = "Descending" },
    .{ .id = .sort_folders_first, .label = "Folders First" },
};

const more_lines = [_]Line{
    .{ .id = .view_list },
    .{ .id = .view_column },
    sep,
    .{ .id = .view_hidden },
    .{ .id = .file_new_folder },
    sep,
    .{ .id = .view_split_side },
    .{ .id = .view_split_stacked },
    .{ .id = .palette_show },
};

/// A toolbar button that opens (or closes) menu `kind` of pane `pane_id`.
pub fn button(c: *ui.Context, m: *Model, pane_id: u32, kind: Kind, key: []const u8, symbol: []const u8, active: bool) void {
    const st = &m.view_state.toolbar_menu;
    const mine = st.open and st.pane == pane_id and st.kind == kind;
    const b = style.iconButtonAt(c, key, symbol, true, active or mine);
    if (mine) if (b.rect) |r| {
        st.anchor = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    };
    if (!b.clicked) return;
    if (mine) {
        st.open = false;
        return;
    }
    // The pane takes the focus first: the menu's check marks read the focused pane.
    style.post(c, m, .{ .focus_pane = pane_id });
    st.* = .{ .open = true, .kind = kind, .pane = pane_id, .anchor = if (b.rect) |r| .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h } else null };
}

/// The open menu, over the panes (called once by the panes view).
pub fn popover(c: *ui.Context, m: *Model) void {
    const st = &m.view_state.toolbar_menu;
    const anchor: ?ui.Rect = if (st.anchor) |a| .{ .x = a.x, .y = a.y, .w = a.w, .h = a.h } else null;
    const lines: []const Line = if (st.kind == .sort) &sort_lines else &more_lines;
    const p = kit.popover(c, "toolbar-menu", &st.open, anchor, .{ .placement = .bottom_end, .width = if (st.kind == .sort) 216 else 244, .padding = 5 }) orelse return;
    defer p.end();
    const built = context_menu.build(c, m, lines) orelse return;
    if (st.kind == .sort) {
        const head = ui.div(c).wFull().px(8).pt(4).pb(4);
        defer head.end();
        ui.text(c, "Sort By", .{ .size = 11, .weight = .semibold, .color = c.theme.muted });
    }
    const chosen = context_menu.rows(c, built.items) orelse return;
    st.open = false;
    c.changed = true;
    if (built.ids[chosen]) |id| {
        style.post(c, m, .{ .focus_pane = st.pane });
        style.post(c, m, .{ .run_command = id });
    }
}
