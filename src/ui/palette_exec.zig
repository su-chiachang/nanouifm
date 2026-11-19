//! What choosing a folder or a file in the palette does (`Action.palette_open`): like Swift's
//! `openLocation`. A path that is gone raises the banner. A folder goes to the focused pane
//! (Return), a new tab (Cmd+Return) or a pane docked beside it (Opt+Return). A file opens in its
//! default app through the injected opener (Return); Cmd+Return and Opt+Return show it instead,
//! selected in its folder, in a new tab or a split.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const lister = @import("../core/lister.zig");
const pm = @import("palette_model.zig");
const tab_ops = @import("tab_ops.zig");
const layout_ops = @import("layout_ops.zig");
const refresh = @import("file_refresh.zig");

pub fn open(m: *Model, o: pm.Open) Allocator.Error!void {
    const item = (try lister.item(m.gpa, o.path)) orelse {
        var buf: [600]u8 = undefined;
        return m.raise(std.fmt.bufPrint(&buf, "\u{201C}{s}\u{201D} no longer exists.", .{std.fs.path.basename(o.path)}) catch "That item no longer exists.");
    };
    defer item.deinit(m.gpa);
    if (item.is_directory) return openFolder(m, o.path, o.target);
    const parent = std.fs.path.dirname(o.path) orelse return;
    switch (o.target) {
        .here => try m.openFile(o.path),
        .new_tab => try tab_ops.openInNewTab(m, parent),
        .split => try layout_ops.dock(m, m.focused, .right, parent),
    }
    if (o.target != .here) try refresh.select(m, m.focused, &.{o.path});
}

fn openFolder(m: *Model, path: []const u8, target: pm.OpenTarget) Allocator.Error!void {
    switch (target) {
        .here => try m.navigate(path),
        .new_tab => try tab_ops.openInNewTab(m, path),
        .split => try layout_ops.dock(m, m.focused, .right, path),
    }
}
