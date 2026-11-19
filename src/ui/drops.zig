//! Dropping files on a folder: from Finder or another app (nanoui's native drop, `acceptDrop` /
//! `dropAt`, whose URLs are file URLs) and from another pane of this window (nanoui's in-window
//! drag, `dragSource` / `dropTarget`, whose payload is the pane the rows come from). Either way
//! the drop is queued as `Action.drop_files`, so it runs through `FileOperationService`: a move,
//! or a copy with Option. A drop onto the folder a pane shows, or onto a folder row, lands there;
//! a sidebar row is a folder too.
//!
//! nanoui can't start a drag of files OUT of the window (`Context.startDrag` carries text only),
//! so dragging items to Finder is not possible; pane-to-pane works.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const target = @import("file_target.zig");
const style = @import("style.zig");
const drag_kind = @import("drag_kind.zig");

/// The absolute path a file URL names ("file:///Users/me/a%20b/" -> "/Users/me/a b"), in `a`;
/// null for anything that isn't a file URL.
pub fn pathOfUrl(a: Allocator, url: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;
    var rest = url[prefix.len..];
    if (std.ascii.startsWithIgnoreCase(rest, "localhost/")) rest = rest["localhost".len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    if (std.mem.indexOfAny(u8, rest, "?#")) |end| rest = rest[0..end];
    var out = a.alloc(u8, rest.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                out[n] = b;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = rest[i];
        n += 1;
    }
    while (n > 1 and out[n - 1] == '/') n -= 1;
    return out[0..n];
}

/// Whether the drop is a copy: Option held (the tester's modifiers, or the real keyboard via the hook).
fn wantsCopy(c: *ui.Context, m: *const Model) bool {
    return c.input.alt or (if (m.hooks.option_held) |f| f() else false);
}

/// Box `index` takes drops from other apps (files): what lands on it goes into `dest`. Call
/// after the box's contents, so a folder row inside it is asked first (it takes the drop).
pub fn accept(c: *ui.Context, m: *Model, index: u32, dest: []const u8) void {
    c.acceptDrop(index);
    const d = c.dropAt(index) orelse return;
    c.input.drop = null; // taken: boxes around this one don't also take it
    var paths: std.ArrayList([]const u8) = .empty;
    for (d.urls) |u| if (pathOfUrl(c.alloc(), u)) |p| paths.append(c.alloc(), p) catch return;
    if (paths.items.len == 0) return;
    style.post(c, m, .{ .drop_files = .{ .paths = paths.items, .dest = dest, .copy = wantsCopy(c, m) } });
}

/// A drag of this window's own rows may land in `rect` (a folder row, a pane, a sidebar row):
/// the rows selected in the pane it came from go into `dest`. Skips a folder dropped on itself.
/// True while a drag is over it (to highlight).
pub fn land(c: *ui.Context, m: *Model, rect: ?ui.Rect, dest: []const u8) bool {
    const r = rect orelse return false;
    const over = ui.dragOver(c, r) != null and m.view_state.file_drag != null;
    const payload = ui.dropTarget(c, r) orelse return over;
    dropFiles(c, m, payload, dest);
    return false;
}

/// A drop that was taken (`ui.dropTarget`): when it is a pane's rows, the ones selected there go
/// into `dest`. A sidebar entry's drag (`drag_kind`) is not files and does nothing here.
pub fn dropFiles(c: *ui.Context, m: *Model, payload: u64, dest: []const u8) void {
    const src_id = drag_kind.asPane(payload) orelse return;
    const si = m.paneIndex(src_id) orelse return;
    const paths = target.selectedPaths(c.alloc(), &m.panes.items[si]) catch return;
    for (paths) |p| if (std.mem.eql(u8, p, dest)) return;
    if (paths.len == 0) return;
    style.post(c, m, .{ .drop_files = .{ .paths = paths, .dest = dest, .copy = wantsCopy(c, m) } });
}

/// The drag's label beside the pointer, while rows are dragged (called once, last).
pub fn ghost(c: *ui.Context, m: *Model) void {
    const a = ui.dragging(c) orelse {
        m.view_state.file_drag = null;
        return;
    };
    const pane_id = m.view_state.file_drag orelse return;
    const pi = m.paneIndex(pane_id) orelse return;
    const n = target.count(&m.panes.items[pi]);
    const th = c.theme;
    ui.key(c, "file-drag-ghost");
    const g = ui.div(c).fixed().offset(a.point.x + 14, a.point.y + 14).layer(40).px(10).py(5).rounded(8).bg(th.accent);
    defer g.end();
    var buf: [48]u8 = undefined;
    const label = if (n == 1) "1 item" else std.fmt.bufPrint(&buf, "{d} items", .{n}) catch "items";
    ui.text(c, c.alloc().dupe(u8, label) catch label, .{ .size = 12, .weight = .medium, .color = th.accent_text });
}
