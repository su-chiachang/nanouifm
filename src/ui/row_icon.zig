//! One file's icon as the rows, the path bar and the inspector draw it: Finder's icon for its type
//! when `Hooks.file_icon` has delivered it (`file_icons.zig`), else the generic SF symbol the caller
//! names. Drawing only READS the cache; the first lookup of a key asks the provider and this frame
//! keeps the symbol. Exactly one leaf either way, of the same box, so nothing shifts when an icon
//! arrives. No provider: the symbol, and not even a key is made.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const FileItem = @import("../core/lister.zig").FileItem;
const kinds = @import("../core/file_kinds.zig");
const Model = @import("model.zig").Model;
const file_icons = @import("file_icons.zig");

/// What an item's icon is asked for by: folders share one key, files their lowercased extension
/// (kept in `buf`), applications their own path (every one has its own icon); anything else
/// without an extension is a generic file.
pub fn keyFor(item: FileItem, buf: *[file_icons.max_ext]u8) file_icons.Key {
    if (item.is_directory) return .folder;
    const ext = kinds.extensionOf(item.name);
    if (ext.len == 0 or ext.len > buf.len) return .file;
    const lower = std.ascii.lowerString(buf, ext);
    if (item.is_package and std.mem.eql(u8, lower, "app")) return .{ .path = item.path };
    return .{ .ext = lower };
}

/// The icon for `key` in a `box` points square (pixels at `side`), or `symbol` drawn with `opts`.
pub fn draw(c: *ui.Context, m: *Model, key: file_icons.Key, side: u32, box: f32, symbol: []const u8, opts: ui.IconOptions) void {
    if (m.hooks.file_icon) |_| {
        if (m.preview.icons.lookup(m.hooks.file_icon, key, side)) |r| {
            const drawn = ui.image(c, .{
                .key = r.key,
                .source = .{ .pixels = .{ .bgra = r.px.bgra, .width = r.px.width, .height = r.px.height } },
                .box = .{ .w = box, .h = box },
                .radius = 0,
            });
            if (drawn) return;
        }
    }
    ui.icon(c, symbol, opts);
}

/// A row's icon: 16 points, the item's own look as the fallback.
pub fn drawItem(c: *ui.Context, m: *Model, item: FileItem, symbol: []const u8, color: ui.Color) void {
    var buf: [file_icons.max_ext]u8 = undefined;
    const key = if (m.hooks.file_icon != null) keyFor(item, &buf) else .file;
    draw(c, m, key, file_icons.row_side, 16, symbol, .{ .size = 14, .frame = 16, .color = color });
}
