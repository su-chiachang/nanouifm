//! The trailing preview column of column view: the selected file's preview and details, the same
//! component as the list's inspector (`item_panel.zig`), in a column of `cm.preview_width`.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const FileItem = @import("../core/lister.zig").FileItem;
const cm = @import("column_model.zig");
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const item_panel = @import("item_panel.zig");

pub fn view(c: *ui.Context, m: *Model, pane: *const Pane, item: FileItem) void {
    ui.key(c, "preview");
    const box = ui.div(c).column().w(cm.preview_width).hFull().clip();
    defer box.end();
    item_panel.view(c, m, pane, item, cm.preview_width);
}
