//! What the inspector says about a selection, as plain data (the view draws it, tests check it):
//! the abbreviated path ("~/Documents"), the totals of several items, and the layout numbers
//! of the side panel.
const std = @import("std");
const FileItem = @import("../core/lister.zig").FileItem;

/// `dir` with the home folder written "~".
pub fn abbreviate(buf: []u8, home: []const u8, dir: []const u8) []const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, dir, home) and (dir.len == home.len or dir[home.len] == '/')) {
        return std.fmt.bufPrint(buf, "~{s}", .{dir[home.len..]}) catch dir;
    }
    return dir;
}

pub const Totals = struct {
    count: usize,
    folders: usize,
    /// The bytes of the files (a folder's size is not counted: the listing doesn't know it).
    bytes: i64,
};

pub fn totals(items: []const FileItem) Totals {
    var t: Totals = .{ .count = items.len, .folders = 0, .bytes = 0 };
    for (items) |it| {
        if (it.is_directory) t.folders += 1;
        if (it.size) |s| t.bytes += s;
    }
    return t;
}

/// The room the list keeps beside the panel: Name and Size (what a four-column layout of the same
/// window leaves it, too).
pub const list_min: f32 = 250;
pub const panel_min: f32 = 170;

/// The side panel's width in a pane `pane_w` wide: about 38%, but the list keeps `list_min` (below
/// that the panel keeps `panel_min` and the list what is left).
pub fn panelWidth(pane_w: f32) f32 {
    const p = std.math.clamp(pane_w * 0.38, 200, 300);
    return if (pane_w - p < list_min) @max(panel_min, pane_w - list_min) else p;
}

/// The longer side (points) a thumbnail is asked for: one size for every panel width, so a
/// resized panel does not ask again.
pub const thumb_side: u32 = 520;

const testing = std.testing;

fn fake(size: ?i64, dir: bool) FileItem {
    return .{ .path = "/x", .name = "x", .is_directory = dir, .is_package = false, .is_hidden = false, .is_symlink = false, .size = size, .modified = null, .created = null, .kind = "k" };
}

test "paths are abbreviated from home" {
    var b: [64]u8 = undefined;
    try testing.expectEqualStrings("~/Documents/a", abbreviate(&b, "/Users/me", "/Users/me/Documents/a"));
    try testing.expectEqualStrings("~", abbreviate(&b, "/Users/me", "/Users/me"));
    try testing.expectEqualStrings("/Users/meow", abbreviate(&b, "/Users/me", "/Users/meow"));
    try testing.expectEqualStrings("/opt", abbreviate(&b, "/Users/me", "/opt"));
}

test "totals count files' bytes and folders" {
    const items = [_]FileItem{ fake(100, false), fake(null, true), fake(23, false) };
    const t = totals(&items);
    try testing.expectEqual(@as(usize, 3), t.count);
    try testing.expectEqual(@as(usize, 1), t.folders);
    try testing.expectEqual(@as(i64, 123), t.bytes);
}

test "the panel keeps the list wide enough" {
    try testing.expectEqual(@as(f32, 300), panelWidth(900));
    try testing.expect(444 - panelWidth(444) >= list_min);
    try testing.expectEqual(panel_min, panelWidth(343)); // too narrow for both: the panel keeps its minimum
    try testing.expectEqual(panel_min, panelWidth(200));
}
