//! The inspector's commands: showing it beside the list (a flag of the focused pane) and Share.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const target = @import("file_target.zig");

pub fn isOn(m: *Model) bool {
    return m.focusedPane().inspector;
}

pub fn toggle(m: *Model) Allocator.Error!void {
    const p = m.focusedPane();
    p.inspector = !p.inspector;
}

/// Share: the selected files' sheet, hanging from the Share button that was pressed (or the
/// window's corner when the command comes from a menu). Without a share sheet a notice says so.
pub fn share(m: *Model) Allocator.Error!void {
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try target.selectedPaths(arena.allocator(), m.focusedPane());
    if (paths.len == 0) return;
    const f = m.hooks.share orelse return m.raise("Sharing isn\u{2019}t available here.");
    f(paths, m.preview.share_anchor orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 });
}
