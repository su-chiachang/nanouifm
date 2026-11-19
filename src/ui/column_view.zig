//! A pane's column view drawn: Miller columns side by side in a box that scrolls sideways, each
//! a virtualized list of one folder (chevrons on folders), a draggable divider at the right edge
//! of each, and a trailing preview of a selected file. Clicks queue `Action`s on the model (the
//! pane focused first); resizing and the scroll position are the tab's own state and apply at
//! once. The stack itself is `column_model.zig`, changed by `column_ops.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const cm = @import("column_model.zig");
const listing = @import("listing.zig");
const style = @import("style.zig");
const preview = @import("column_preview.zig");
const row_input = @import("row_input.zig");
const rename_view = @import("rename_view.zig");
const context_menu = @import("context_menu.zig");

const list_edge: f32 = 2;

pub fn view(c: *ui.Context, m: *Model, pane: *Pane, focused: bool) void {
    const tab = pane.tab();
    if (focused) if (m.notice) |n| @import("list_pane.zig").banner(c, m, n);
    ui.keyInt(c, tab.id); // each tab keeps its own scroll
    const area = ui.div(c).column().wFull().grow().clip();
    defer area.end();
    m.view_state.ctx_menu.claimed = false;
    defer context_menu.emptySpaceClicked(c, m, pane.id, area.interaction().secondary_clicked);
    const cs = &tab.col;
    const preview_item = previewItem(cs);

    const strip = c.open(.{ .direction = .row, .scroll_x = true, .width = .fill, .height = .fill }, "columns");
    defer c.end();
    const id = c.node(strip).id;
    if (!c.scroll_x.contains(id) and cs.scroll_x > 0) ui.setScrollOffset(c, id, .x, cs.scroll_x);
    cs.scroll_x = ui.scrollOffset(c, id, .x);
    revealLast(c, cs, id, preview_item != null);

    for (cs.columns.items, 0..) |*col, depth| {
        ui.keyInt(c, depth);
        column(c, m, pane, col, depth, focused and depth == cs.active);
    }
    if (preview_item) |it| preview.view(c, m, pane, it);
    // The room after the last column, so the strip always fills the pane.
    _ = c.leaf(.{ .grow = 1, .height = .fill }, .none, "rest");
}

/// The selected file shown in the trailing preview: the last column's single selection, if not a folder.
fn previewItem(cs: *cm.ColumnState) ?@import("../core/lister.zig").FileItem {
    const last = cs.last() orelse return null;
    const it = last.single() orelse return null;
    return if (it.is_directory) null else it;
}

/// After a column was added or dropped, scroll sideways just far enough to show the last one.
fn revealLast(c: *ui.Context, cs: *cm.ColumnState, id: u64, with_preview: bool) void {
    if (!cs.reveal) return;
    const r = c.rects.get(id) orelse return; // laid out once first
    cs.reveal = false;
    const want = cs.contentWidth(with_preview) - r.w;
    if (want > ui.scrollOffset(c, id, .x)) ui.setScrollOffset(c, id, .x, want);
}

fn column(c: *ui.Context, m: *Model, pane: *Pane, col: *cm.Column, depth: usize, active: bool) void {
    const th = c.theme;
    const tab = pane.tab();
    const w = tab.col.width(depth);
    const box = ui.div(c).row().w(w).hFull();
    defer box.end();
    {
        const body = ui.div(c).column().grow().minW(0).hFull().clip();
        defer body.end();
        rows(c, m, pane, col, depth, active);
    }
    divider(c, m, pane, tab, depth, w, th);
}

fn message(c: *ui.Context, text: []const u8) void {
    const msg = ui.div(c).sizeFull().center().p(12);
    defer msg.end();
    ui.text(c, text, .{ .size = 12.5, .color = c.theme.muted });
}

fn rows(c: *ui.Context, m: *Model, pane: *const Pane, col: *cm.Column, depth: usize, active: bool) void {
    const th = c.theme;
    if (col.listing.err) |e| return message(c, listing.errorText(e));
    const items = col.items();
    if (items.len == 0) return message(c, if (pane.filter.isActive() and depth == pane.tabs.items[pane.active].col.filter_col) "No Matches" else "Empty Folder");
    const list_id = c.peekId(null);
    var scroll_to: ?f32 = null;
    if (col.reveal) |row| {
        scroll_to = style.revealOffset(c, list_id, row, style.row_height, list_edge);
        col.reveal = null;
    }
    var list = ui.list(c, .{
        .count = items.len,
        .row_height = style.row_height,
        .padding = .{ .left = 6, .right = 6, .top = list_edge, .bottom = list_edge },
        .scroll_to = scroll_to,
    });
    while (list.next()) |i| {
        const item = items[i];
        const selected = col.selection.contains(item.path);
        const lit = selected and active;
        var r = ui.div(c).row().wFull().h(style.row_height).px(6).gap(6).itemsCenter().rounded(6).control();
        r = if (lit) r.bg(th.accent) else if (selected) r.bg(th.muted.alpha(0.25)) else r.hover(th.surface_hover);
        defer r.end();
        const fg: ui.Color = if (lit) th.accent_text else th.text;
        ui.icon(c, if (item.is_directory) "folder.fill" else if (item.is_package) "app" else "doc", .{
            .size = 14,
            .frame = 16,
            .color = if (lit) th.accent_text else if (item.is_directory) th.accent else th.muted,
        });
        {
            const name = ui.div(c).row().grow().minW(0).clip();
            defer name.end();
            if (rename_view.editing(m, pane.id, item.path)) {
                rename_view.field(c, m);
            } else {
                ui.text(c, item.name, .{ .size = 13, .color = fg, .truncate = .ellipsis });
            }
        }
        if (item.is_directory) ui.icon(c, "chevron.right", .{ .size = 10, .weight = .semibold, .color = if (lit) th.accent_text else th.muted });
        row_input.column(c, m, pane, depth, items, i, selected, r);
    }
    list.end();
}

/// How far past each side of the hairline a press still grabs it.
const grab: f32 = 6;

/// The divider at the right edge of column `depth`: a hairline with a grab band; dragging it
/// sets the column's width (clamped), remembered by the tab.
fn divider(c: *ui.Context, m: *Model, pane: *const Pane, tab: *Tab, depth: usize, w: f32, th: anytype) void {
    ui.key(c, "divider");
    const band = ui.div(c).w(grab).hFull().center();
    defer band.end();
    const it = band.interaction();
    const vs = &m.view_state;
    const mine = if (vs.col_drag) |g| g.pane == pane.id and g.depth == depth else false;
    if (it.hovered or mine) c.cursor = .resize_left_right;
    const x = c.input.mouse.x;
    if (it.pressed and !mine and vs.col_drag == null) {
        vs.col_drag = .{ .pane = pane.id, .depth = @intCast(depth), .last = x };
    } else if (mine) {
        if (!c.input.down) {
            vs.col_drag = null;
        } else if (x != vs.col_drag.?.last) {
            const got = tab.col.setWidth(m.gpa, depth, w + (x - vs.col_drag.?.last)) catch w;
            vs.col_drag.?.last += got - w; // the pointer past a limit waits for the edge to come back
            c.changed = true;
        }
    }
    const hot = (it.hovered and vs.col_drag == null) or mine;
    const line = ui.div(c).w(if (hot) 3 else 1).hFull().bg(if (hot) th.accent.alpha(0.55) else th.border);
    line.end();
}
