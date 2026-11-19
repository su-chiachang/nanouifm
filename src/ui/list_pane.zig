//! The list inside a pane: the notice banner, the column header and the virtualized rows of the
//! pane's shown tab. Clicks that change the folder or the order are queued on the model (with the
//! pane focused first); selection changes apply at once.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const lister = @import("../core/lister.zig");
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const listing = @import("listing.zig");
const format = @import("format.zig");
const style = @import("style.zig");

/// The list below a pane's toolbar: the notice banner (in the focused pane), the column header
/// and the rows of the shown tab. `w` is the pane's width: narrow panes drop the Kind and Date
/// columns.
pub fn view(c: *ui.Context, m: *Model, pane: *Pane, focused: bool, w: f32) void {
    const tab = pane.tab();
    const cols = style.columnsFor(w);
    if (focused) if (m.notice) |n| banner(c, m, n);
    header(c, m, pane, cols);
    ui.divider(c);
    rows(c, m, pane, tab, cols);
}

fn banner(c: *ui.Context, m: *Model, text: []const u8) void {
    const th = c.theme;
    const b = ui.div(c).row().wFull().px(style.pad).py(6).gap(8).itemsCenter().bg(th.danger.alpha(0.12)).control();
    defer b.end();
    ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 13, .color = th.danger });
    ui.text(c, text, .{ .size = 12.5, .truncate = .ellipsis });
    ui.spacer(c);
    ui.text(c, "Dismiss", .{ .size = 12, .color = th.muted });
    if (b.clicked()) m.queue(.clear_notice) catch {};
}

fn header(c: *ui.Context, m: *Model, pane: *const Pane, cols: style.Columns) void {
    const bar = ui.div(c).row().wFull().h(style.header_height).px(style.pad + 6).itemsCenter();
    defer bar.end();
    const sort = pane.sort;
    var clicked: ?lister.SortKey = null;
    if (headerCell(c, "Name", .name, sort, null, false)) clicked = .name;
    if (cols.kind and headerCell(c, "Kind", .kind, sort, style.kind_width, false)) clicked = .kind;
    if (headerCell(c, "Size", .size, sort, style.size_width, true)) clicked = .size;
    if (cols.date and headerCell(c, "Date Modified", .modified, sort, style.date_width, false)) clicked = .modified;
    if (clicked) |k| {
        style.post(c, m, .{ .focus_pane = pane.id });
        style.post(c, m, .{ .sort = k });
    }
}

/// One column title; a fixed `width`, or the rest of the row when null. True if clicked.
fn headerCell(c: *ui.Context, title: []const u8, key: lister.SortKey, sort: lister.SortOrder, width: ?f32, right: bool) bool {
    const th = c.theme;
    ui.key(c, title);
    var cell = ui.div(c).row().hFull().gap(4).itemsCenter().control();
    cell = if (width) |w| cell.w(w) else cell.grow();
    if (right) cell = cell.justifyEnd().pr(14); // lined up with the sizes below
    defer cell.end();
    const active = sort.key == key;
    ui.text(c, title, .{ .size = 12, .weight = .medium, .color = if (active) th.text else th.muted });
    if (active) ui.icon(c, if (sort.ascending) "chevron.up" else "chevron.down", .{ .size = 9, .weight = .bold, .color = th.muted });
    const it = cell.interaction();
    if (it.clicked) c.changed = true;
    return it.clicked;
}

fn rows(c: *ui.Context, m: *Model, pane: *const Pane, tab: *Tab, cols: style.Columns) void {
    const th = c.theme;
    // Keyed by the tab, so each tab keeps its own scroll position.
    ui.keyInt(c, tab.id);
    const area = ui.div(c).column().wFull().grow().clip();
    defer area.end();
    const items = tab.listing.visible;
    if (tab.listing.err) |e| {
        const msg = ui.div(c).sizeFull().center();
        defer msg.end();
        ui.text(c, listing.errorText(e), .{ .size = 13, .color = th.muted });
        return;
    }
    if (items.len == 0) {
        const msg = ui.div(c).sizeFull().center();
        defer msg.end();
        ui.text(c, "This folder is empty", .{ .size = 13, .color = th.muted });
        return;
    }
    var list = ui.list(c, .{
        .count = items.len,
        .row_height = style.row_height,
        .padding = .{ .left = style.pad, .right = style.pad, .top = 2, .bottom = 2 },
        .scroll_to = if (tab.scroll_reset) 0 else null,
    });
    tab.scroll_reset = false;
    while (list.next()) |i| {
        const item = items[i];
        const selected = tab.selection.contains(item.path);
        var r = ui.div(c).row().wFull().h(style.row_height).px(6).itemsCenter().rounded(6).control();
        r = if (selected) r.bg(th.accent) else r.hover(th.surface_hover);
        defer r.end();
        rowCells(c, item, selected, cols);
        const it = r.interaction();
        if (it.clicked) {
            c.changed = true;
            style.post(c, m, .{ .focus_pane = pane.id });
            if (it.double_clicked) {
                if (item.is_directory) style.post(c, m, .{ .open = item.path });
            } else {
                tab.selection.click(m.gpa, items, i, .{ .cmd = c.input.cmd, .shift = c.input.shift }) catch {};
            }
        }
    }
    list.end();
}

fn rowCells(c: *ui.Context, item: lister.FileItem, selected: bool, cols: style.Columns) void {
    const th = c.theme;
    const fg: ui.Color = if (selected) th.accent_text else th.text;
    const dim: ui.Color = if (selected) th.accent_text.alpha(0.85) else th.muted;
    {
        const name = ui.div(c).row().grow().minW(0).gap(8).pr(8).itemsCenter().clip();
        defer name.end();
        ui.icon(c, if (item.is_directory) "folder.fill" else if (item.is_package) "app" else "doc", .{
            .size = 14,
            .frame = 16,
            .color = if (selected) th.accent_text else if (item.is_directory) th.accent else th.muted,
        });
        ui.text(c, item.name, .{ .size = 13, .color = fg, .truncate = .ellipsis });
    }
    if (cols.kind) {
        const k = ui.div(c).w(style.kind_width).clip();
        defer k.end();
        ui.text(c, item.kind, .{ .size = 12, .color = dim, .truncate = .ellipsis });
    }
    {
        const s = ui.div(c).row().w(style.size_width).justifyEnd().pr(14);
        defer s.end();
        var buf: [32]u8 = undefined;
        const txt = if (item.size) |n| format.size(&buf, n) else "--";
        ui.text(c, c.print("{s}", .{txt}), .{ .size = 12, .color = dim, .tabular = true });
    }
    if (cols.date) {
        const d = ui.div(c).w(style.date_width).clip();
        defer d.end();
        var buf: [48]u8 = undefined;
        const txt = if (item.modified) |ns| format.localDate(&buf, ns) else "--";
        ui.text(c, c.print("{s}", .{txt}), .{ .size = 12, .color = dim });
    }
}
