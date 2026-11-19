//! The path bar at the bottom of a pane: breadcrumbs of the folder (from Home when inside it,
//! else from the volume root), with the item count beside them. A click on a crumb queues
//! navigation of the pane to it. A crumb is also a drop target: files dropped on it (from Finder,
//! or dragged from a pane) move into that folder, a copy with Option, through `drops.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const style = @import("style.zig");
const drops = @import("drops.zig");
const row_icon = @import("row_icon.zig");
const file_icons = @import("file_icons.zig");

pub const Crumb = struct {
    /// The folder's path: a prefix of the path crumbs were made from.
    path: []const u8,
    name: []const u8,
};

pub const max_crumbs = 96;

/// The chain of folders to `path`: starting at `home` if `path` is `home` or inside it, else at "/".
/// Deeper chains keep their last `max_crumbs`. Returns the filled prefix of `out`.
pub fn crumbs(out: *[max_crumbs]Crumb, home: []const u8, path: []const u8) []const Crumb {
    var n: usize = 0;
    const in_home = home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/');
    var start_end: usize = if (in_home) home.len else 1;
    if (path.len <= 1) start_end = path.len;
    push(out, &n, .{ .path = path[0..start_end], .name = if (in_home) std.fs.path.basename(home) else "Macintosh HD" });
    var i: usize = start_end;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') i += 1;
        if (i >= path.len) break;
        const s = i;
        while (i < path.len and path[i] != '/') i += 1;
        push(out, &n, .{ .path = path[0..i], .name = path[s..i] });
    }
    return out[0..n];
}

fn push(out: *[max_crumbs]Crumb, n: *usize, cr: Crumb) void {
    if (n.* == max_crumbs) {
        std.mem.copyForwards(Crumb, out[0 .. max_crumbs - 1], out[1..max_crumbs]);
        n.* -= 1;
    }
    out[n.*] = cr;
    n.* += 1;
}

/// `w` is the pane's width: it decides how many crumbs fit.
pub fn view(c: *ui.Context, m: *Model, pane: *Pane, w: f32) void {
    const th = c.theme;
    const tab = pane.tab();
    const bar = ui.div(c).row().wFull().h(style.path_bar_height).px(style.pad).gap(2).itemsCenter().bg(th.surface);
    defer bar.end();
    var buf: [max_crumbs]Crumb = undefined;
    const chain = crumbs(&buf, m.home, tab.path());
    // Room for about this many crumbs beside the count; the middle ones collapse into "…".
    const room: usize = @max(3, @as(usize, @intFromFloat(@max(0, w - 180) / 96)));
    const collapse = chain.len > room;
    for (chain, 0..) |cr, i| {
        const last = i + 1 == chain.len;
        if (collapse and i >= 1 and i < chain.len - (room - 1)) {
            if (i == 1) {
                ui.icon(c, "chevron.right", .{ .size = 8, .weight = .semibold, .color = th.muted.alpha(0.7) });
                ui.text(c, "…", .{ .size = 12, .color = th.muted });
            }
            continue;
        }
        if (i > 0) ui.icon(c, "chevron.right", .{ .size = 8, .weight = .semibold, .color = th.muted.alpha(0.7) });
        ui.key(c, c.print("crumb-{d}", .{i}));
        const b = ui.div(c).row().h(22).px(5).gap(4).itemsCenter().rounded(5).hover(th.surface_hover).control();
        defer b.end();
        // The root and the home folder have icons of their own; every other crumb is a plain folder.
        const own = isHome(m.home, cr.path) or (i == 0 and std.mem.eql(u8, cr.path, "/"));
        row_icon.draw(c, m, if (own) .{ .path = cr.path } else .folder, file_icons.row_side, 14, if (i == 0 and !isHome(m.home, cr.path)) "externaldrive" else if (isHome(m.home, cr.path)) "house" else "folder.fill", .{
            .size = 11,
            .color = if (last) th.accent else th.muted,
        });
        ui.text(c, cr.name, .{ .size = 12, .weight = if (last) .semibold else .regular, .color = if (last) th.text else th.muted, .truncate = .ellipsis });
        const it = b.interaction();
        // Files dropped on a crumb go into that folder (a move; Option copies), as on a folder row.
        drops.accept(c, m, b.index, cr.path);
        if (drops.land(c, m, it.rect, cr.path)) c.node(b.index).style.background = th.accent.alpha(0.3);
        if (it.clicked) {
            style.post(c, m, .{ .focus_pane = pane.id });
            style.post(c, m, .{ .open = cr.path });
        }
    }
    ui.spacer(c);
    const n = tab.listing.visible.len;
    const sel = tab.selection.count();
    // A folder being read (a navigation, a column's, a first listing) says so instead of counting.
    const loading = m.loader.loading(tab.id, tab.listed);
    const text = if (loading) "Loading\u{2026}" else if (sel > 0) c.print("{d} of {d} selected", .{ sel, n }) else if (n == 1) "1 item" else c.print("{d} items", .{n});
    ui.text(c, text, .{ .size = 11.5, .color = if (loading) th.accent else th.muted, .tabular = true });
}

fn isHome(home: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, home, path);
}

test "crumbs from home, from the root, and the root itself" {
    var buf: [max_crumbs]Crumb = undefined;
    var cs = crumbs(&buf, "/Users/me", "/Users/me/Docs/x");
    try std.testing.expectEqual(@as(usize, 3), cs.len);
    try std.testing.expectEqualStrings("me", cs[0].name);
    try std.testing.expectEqualStrings("/Users/me", cs[0].path);
    try std.testing.expectEqualStrings("/Users/me/Docs", cs[1].path);
    try std.testing.expectEqualStrings("x", cs[2].name);
    cs = crumbs(&buf, "/Users/me", "/opt/a");
    try std.testing.expectEqual(@as(usize, 3), cs.len);
    try std.testing.expectEqualStrings("Macintosh HD", cs[0].name);
    try std.testing.expectEqualStrings("/", cs[0].path);
    try std.testing.expectEqualStrings("/opt", cs[1].path);
    cs = crumbs(&buf, "/Users/me", "/");
    try std.testing.expectEqual(@as(usize, 1), cs.len);
    cs = crumbs(&buf, "/Users/me", "/Users/meow");
    try std.testing.expectEqualStrings("Macintosh HD", cs[0].name); // not inside "me"
}
