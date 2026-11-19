//! The inspector beside a pane's list (Opt+Cmd+I, the toolbar's button): "No Selection", the
//! count and total size of several items, or one item's preview and details (`item_panel.zig`).
//! It follows the selection of the pane it belongs to, so two panes can each have their own.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const FileItem = @import("../core/lister.zig").FileItem;
const target = @import("file_target.zig");
const format = @import("format.zig");
const info = @import("inspector_info.zig");
const item_panel = @import("item_panel.zig");

/// The panel, `w` points wide and as tall as the pane's body, with a hairline at its left.
pub fn view(c: *ui.Context, m: *Model, pane: *Pane, w: f32) void {
    const th = c.theme;
    ui.key(c, "inspector");
    const box = ui.div(c).row().w(w).hFull().bg(th.background.mix(th.surface, 0.5));
    defer box.end();
    {
        ui.key(c, "edge");
        const line = ui.div(c).w(1).hFull().bg(th.border);
        line.end();
    }
    const content = ui.div(c).column().grow().minW(0).hFull().clip();
    defer content.end();
    const items: []const FileItem = target.selected(c.alloc(), pane) catch &.{};
    switch (items.len) {
        0 => placeholder(c, "doc.text.magnifyingglass", "No Selection", null, null),
        1 => item_panel.view(c, m, pane, items[0], w - 1),
        else => {
            const t = info.totals(items);
            var sbuf: [32]u8 = undefined;
            const title = c.print("{d} items", .{t.count});
            const sub = c.print("{s} total", .{format.size(&sbuf, t.bytes)});
            placeholder(c, "square.stack.3d.up", title, sub, if (t.folders > 0) "folders not counted" else null);
        },
    }
}

/// The panel's message: an icon and up to three lines, all centred under it. Each line sits in a
/// full-width, clipped row that centres it and cuts it with an ellipsis when the panel is too
/// narrow, so a long line never pushes the others off-centre.
fn placeholder(c: *ui.Context, symbol: []const u8, title: []const u8, sub: ?[]const u8, note: ?[]const u8) void {
    const th = c.theme;
    ui.key(c, "placeholder");
    const box = ui.div(c).column().sizeFull().center().gap(8).p(16);
    defer box.end();
    ui.icon(c, symbol, .{ .size = 28, .color = th.muted.alpha(0.7) });
    centred(c, "title", title, .{ .size = 14, .weight = .medium, .color = if (sub == null) th.muted else th.text });
    if (sub) |s| centred(c, "sub", s, .{ .size = 12, .color = th.muted });
    if (note) |s| centred(c, "note", s, .{ .size = 11.5, .color = th.muted.alpha(0.8) });
}

fn centred(c: *ui.Context, key: []const u8, str: []const u8, style: ui.TextStyle) void {
    ui.key(c, key);
    const row = ui.div(c).row().wFull().minW(0).justifyCenter().clip();
    defer row.end();
    var s = style;
    s.truncate = .ellipsis;
    ui.text(c, str, s);
}
