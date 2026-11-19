//! One item's preview and details, drawn in a box `w` points wide: the inspector beside the list
//! and the trailing preview column of column view are this same component. From the top: the
//! big preview (the thumbnail when `Hooks.thumbnail` has delivered one, else the file's icon),
//! the name and abbreviated path, the buttons Open / Reveal / Path / Share, and the Details
//! (Kind, Size, Resolution for pictures, Created, Modified).
//!
//! The buttons act on the pane's selection through the registry (`file_open`, `file_reveal`,
//! `file_copy_path`, `file_share`), the pane focused first, so they do what the menu items do.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const FileItem = @import("../core/lister.zig").FileItem;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const style = @import("style.zig");
const format = @import("format.zig");
const info = @import("inspector_info.zig");
const image_info = @import("image_info.zig");
const CommandId = @import("command_id.zig").Id;

pub const pad: f32 = 16;

/// The icon standing for a file where there is no thumbnail.
pub fn symbolFor(item: FileItem) []const u8 {
    return if (item.is_directory) "folder.fill" else if (item.is_package) "app" else "doc";
}

pub fn view(c: *ui.Context, m: *Model, pane: *const Pane, item: FileItem, w: f32) void {
    ui.key(c, "item-panel");
    const body = ui.div(c).column().wFull().hFull().p(pad).gap(12).scrollY().scrollBarIdle(1.5);
    defer body.end();
    const inner = w - 2 * pad;
    preview(c, m, item, inner);
    heading(c, m, item);
    buttons(c, m, pane, inner);
    ui.text(c, "Details", .{ .size = 13, .weight = .semibold });
    details(c, m, item, inner);
}

fn preview(c: *ui.Context, m: *Model, item: FileItem, inner: f32) void {
    const th = c.theme;
    ui.key(c, "preview-box");
    const box_h = std.math.clamp(inner * 0.72, 110, 220);
    const box = ui.div(c).wFull().h(box_h).center().rounded(10).bg(th.text.alpha(0.05)).clip();
    defer box.end();
    if (m.preview.thumbs.lookup(m.hooks.thumbnail, item.path, item.modified orelse 0, info.thumb_side)) |r| {
        const drawn = ui.image(c, .{
            .key = r.key,
            .source = .{ .pixels = .{ .bgra = r.px.bgra, .width = r.px.width, .height = r.px.height } },
            .max_width = @max(8, inner - 16),
            .max_height = box_h - 16,
            .radius = 4,
            .scale = 2,
        });
        if (drawn) return;
    }
    ui.icon(c, symbolFor(item), .{ .size = 56, .frame = 64, .color = if (item.is_directory) th.accent else th.muted });
}

fn heading(c: *ui.Context, m: *Model, item: FileItem) void {
    const th = c.theme;
    ui.key(c, "heading");
    const col = ui.div(c).column().wFull().gap(3);
    defer col.end();
    ui.text(c, item.name, .{ .size = 14, .weight = .semibold, .wrap = true, .max_lines = 2 });
    var buf: [1100]u8 = undefined;
    const dir = std.fs.path.dirname(item.path) orelse item.path;
    ui.text(c, c.print("{s}", .{info.abbreviate(&buf, m.home, dir)}), .{ .size = 11.5, .color = th.muted, .truncate = .middle });
}

/// Open, Reveal, Path and Share: one row when the panel is wide enough, else two by two.
fn buttons(c: *ui.Context, m: *Model, pane: *const Pane, inner: f32) void {
    const one_row = inner >= 270;
    ui.key(c, "actions");
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    {
        ui.key(c, "r1");
        const row = ui.div(c).row().wFull().gap(6);
        defer row.end();
        action(c, m, pane, "Open", "arrow.up.forward.app", .file_open);
        action(c, m, pane, "Reveal", "magnifyingglass", .file_reveal);
        if (one_row) {
            action(c, m, pane, "Path", "doc.on.clipboard", .file_copy_path);
            action(c, m, pane, "Share", "square.and.arrow.up", .file_share);
        }
    }
    if (!one_row) {
        ui.key(c, "r2");
        const row = ui.div(c).row().wFull().gap(6);
        defer row.end();
        action(c, m, pane, "Path", "doc.on.clipboard", .file_copy_path);
        action(c, m, pane, "Share", "square.and.arrow.up", .file_share);
    }
}

fn action(c: *ui.Context, m: *Model, pane: *const Pane, label: []const u8, symbol: []const u8, id: CommandId) void {
    const th = c.theme;
    ui.key(c, label);
    const b = ui.div(c).row().grow().minW(0).h(26).px(6).gap(5).itemsCenter().justifyCenter().rounded(6).bg(th.text.alpha(0.07)).hover(th.text.alpha(0.14)).control().clip();
    defer b.end();
    ui.icon(c, symbol, .{ .size = 11, .weight = .medium, .color = th.text });
    ui.text(c, label, .{ .size = 12, .color = th.text });
    const it = b.interaction();
    if (!it.clicked) return;
    c.changed = true;
    if (id == .file_share) if (it.rect) |r| {
        m.preview.share_anchor = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    };
    style.post(c, m, .{ .focus_pane = pane.id });
    style.post(c, m, .{ .run_command = id });
}

fn details(c: *ui.Context, m: *Model, item: FileItem, inner: f32) void {
    var sbuf: [32]u8 = undefined;
    var cbuf: [48]u8 = undefined;
    var mbuf: [48]u8 = undefined;
    var rbuf: [40]u8 = undefined;
    const grid = ui.div(c).column().wFull().gap(8);
    defer grid.end();
    field(c, "Kind", item.kind);
    field(c, "Size", if (item.is_directory) "--" else if (item.size) |n| format.size(&sbuf, n) else "--");
    if (!item.is_directory and !item.is_package) {
        if (m.preview.pixelSize(m.gpa, m.hooks.image_size, item.path, item.modified orelse 0)) |d| field(c, "Resolution", image_info.label(&rbuf, d));
    }
    // A date is wider than a narrow panel has beside its label: it goes under it.
    const stack = inner < 260;
    stackedField(c, "Created", if (item.created) |ns| format.localDate(&cbuf, ns) else "--", stack);
    stackedField(c, "Modified", if (item.modified) |ns| format.localDate(&mbuf, ns) else "--", stack);
}

fn field(c: *ui.Context, label: []const u8, value: []const u8) void {
    ui.key(c, label);
    const row = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer row.end();
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    const v = ui.div(c).row().grow().minW(0).justifyEnd().clip();
    defer v.end();
    ui.text(c, c.print("{s}", .{value}), .{ .size = 12, .tabular = true, .truncate = .ellipsis });
}

/// A field whose value goes under its label when `stack` (the value keeps all the width).
fn stackedField(c: *ui.Context, label: []const u8, value: []const u8, stack: bool) void {
    if (!stack) return field(c, label, value);
    ui.key(c, label);
    const col = ui.div(c).column().wFull().gap(2);
    defer col.end();
    ui.text(c, label, .{ .size = 12, .color = c.theme.muted });
    ui.text(c, c.print("{s}", .{value}), .{ .size = 12, .tabular = true, .truncate = .ellipsis });
}
