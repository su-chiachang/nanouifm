//! The trailing preview column of column view: a selected file's icon, name, kind, size and
//! modified date, from the `FileItem` its column already holds (no thumbnails yet).
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const FileItem = @import("../core/lister.zig").FileItem;
const cm = @import("column_model.zig");
const format = @import("format.zig");

pub fn view(c: *ui.Context, item: FileItem) void {
    const th = c.theme;
    ui.key(c, "preview");
    const box = ui.div(c).column().w(cm.preview_width).hFull().p(16).gap(10).itemsCenter().clip();
    defer box.end();
    ui.icon(c, if (item.is_package) "app" else "doc", .{ .size = 56, .color = th.muted });
    {
        const name = ui.div(c).row().wFull().minW(0).justifyCenter().clip();
        defer name.end();
        ui.text(c, item.name, .{ .size = 14, .weight = .semibold, .truncate = .ellipsis });
    }
    ui.text(c, item.kind, .{ .size = 12, .color = th.muted });
    ui.divider(c);
    var sbuf: [32]u8 = undefined;
    field(c, "Size", if (item.size) |n| format.size(&sbuf, n) else "--");
    var dbuf: [48]u8 = undefined;
    field(c, "Modified", if (item.modified) |ns| format.localDate(&dbuf, ns) else "--");
}

fn field(c: *ui.Context, label: []const u8, value: []const u8) void {
    ui.key(c, label);
    const row = ui.div(c).row().wFull().gap(8).justifyBetween();
    defer row.end();
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    ui.text(c, c.print("{s}", .{value}), .{ .size = 12, .tabular = true });
}
