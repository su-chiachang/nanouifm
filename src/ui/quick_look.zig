//! Quick Look (Space, Cmd+Y): the command that toggles the system panel on the focused pane's
//! selection, and `sync`, which keeps an open panel on the selection as it changes (arrow keys,
//! clicks, a refresh). Everything the system does is behind `Hooks.quick_look` (the real panel is
//! `system_quick_look.zig`; tests record what reaches the hook).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const target = @import("file_target.zig");
const state = @import("quick_look_state.zig");

/// Whether the Quick Look command applies: something is selected, or the panel is up (to close it).
pub fn canRun(m: *Model) bool {
    if (target.count(m.focusedPane()) > 0) return true;
    const ql = m.hooks.quick_look orelse return false;
    return ql.is_open();
}

/// Space and Cmd+Y: closes the panel if it is up, else shows it on the selection (in row order).
pub fn toggle(m: *Model) Allocator.Error!void {
    const ql = m.hooks.quick_look orelse return;
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = try target.selectedPaths(arena.allocator(), m.focusedPane());
    if (ql.is_open()) {
        ql.toggle(&.{});
        m.preview.ql = .{};
        return;
    }
    if (paths.len == 0) return;
    ql.toggle(paths);
    m.preview.ql = .{ .shown = true, .digest = state.digestOf(paths) };
}

/// Once a pass, after the actions ran: an open panel follows the selection. Cheap when it was never
/// shown from here (nothing is asked of the system then).
pub fn sync(m: *Model) void {
    if (!m.preview.ql.shown) return;
    const ql = m.hooks.quick_look orelse return;
    if (!ql.is_open()) { // closed with its own button, or Escape
        m.preview.ql = .{};
        return;
    }
    var arena = std.heap.ArenaAllocator.init(m.gpa);
    defer arena.deinit();
    const paths = target.selectedPaths(arena.allocator(), m.focusedPane()) catch return;
    if (paths.len == 0) return; // keep what it shows rather than an empty panel
    const d = state.digestOf(paths);
    if (d == m.preview.ql.digest) return;
    m.preview.ql.digest = d;
    ql.update(paths);
}
