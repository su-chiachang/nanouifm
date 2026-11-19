//! The list pane: toolbar (back, forward, up, folder name, hidden files), the column header,
//! the virtualized rows, and the notice banner. It draws the focused tab; clicks that change the
//! folder or the order are queued on the model, selection changes apply at once.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const lister = @import("../core/lister.zig");
const Model = @import("model.zig").Model;
const Tab = @import("tab.zig").Tab;
const listing = @import("listing.zig");
const format = @import("format.zig");
const style = @import("style.zig");
const path_bar = @import("path_bar.zig");

pub fn view(c: *ui.Context, m: *Model) void {
    const th = c.theme;
    const tab = m.focusedTab();
    const col = ui.div(c).column().grow().hFull().bg(th.surface).pl(style.sidebar_width).clip();
    defer col.end();
    toolbar(c, m, tab);
    ui.divider(c);
    if (m.notice) |n| banner(c, m, n);
    header(c, m, tab);
    ui.divider(c);
    rows(c, m, tab);
    ui.divider(c);
    path_bar.view(c, m, tab);
}

fn toolbar(c: *ui.Context, m: *Model, tab: *Tab) void {
    const bar = ui.div(c).row().wFull().h(style.toolbar_height).px(style.pad).gap(4).itemsCenter();
    defer bar.end();
    if (style.iconButton(c, "back", "chevron.left", tab.canBack(), false)) m.queue(.back) catch {};
    if (style.iconButton(c, "forward", "chevron.right", tab.canForward(), false)) m.queue(.forward) catch {};
    if (style.iconButton(c, "up", "chevron.up", m.canUp(), false)) m.queue(.up) catch {};
    {
        const t = ui.div(c).px(8);
        defer t.end();
        ui.text(c, tab.title(), .{ .size = 14, .weight = .semibold, .truncate = .ellipsis });
    }
    ui.spacer(c);
    if (style.iconButton(c, "hidden", if (m.show_hidden) "eye" else "eye.slash", true, m.show_hidden)) m.queue(.toggle_hidden) catch {};
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

fn header(c: *ui.Context, m: *Model, tab: *const Tab) void {
    const bar = ui.div(c).row().wFull().h(style.header_height).px(style.pad + 6).itemsCenter();
    defer bar.end();
    if (headerCell(c, "Name", .name, tab.sort, null, false)) m.queue(.{ .sort = .name }) catch {};
    if (headerCell(c, "Kind", .kind, tab.sort, style.kind_width, false)) m.queue(.{ .sort = .kind }) catch {};
    if (headerCell(c, "Size", .size, tab.sort, style.size_width, true)) m.queue(.{ .sort = .size }) catch {};
    if (headerCell(c, "Date Modified", .modified, tab.sort, style.date_width, false)) m.queue(.{ .sort = .modified }) catch {};
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

fn rows(c: *ui.Context, m: *Model, tab: *Tab) void {
    const th = c.theme;
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
        rowCells(c, item, selected);
        const it = r.interaction();
        if (it.clicked) {
            c.changed = true;
            if (it.double_clicked) {
                if (item.is_directory) m.queue(.{ .open = item.path }) catch {};
            } else {
                tab.selection.click(m.gpa, items, i, .{ .cmd = c.input.cmd, .shift = c.input.shift }) catch {};
            }
        }
    }
    list.end();
}

fn rowCells(c: *ui.Context, item: lister.FileItem, selected: bool) void {
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
    {
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
    {
        const d = ui.div(c).w(style.date_width).clip();
        defer d.end();
        var buf: [48]u8 = undefined;
        const txt = if (item.modified) |ns| format.localDate(&buf, ns) else "--";
        ui.text(c, c.print("{s}", .{txt}), .{ .size = 12, .color = dim });
    }
}
