//! List view's keyboard: Up/Down (Shift extends), Home/End, Right and Left (open and close a
//! folder in place, or step to the parent row), and type-to-select, all on the tab's shown rows
//! (`exp.items`) and its selection. Every move marks the row to scroll into sight.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Tab = @import("tab.zig").Tab;
const Opts = @import("tab.zig").Opts;
const NavKey = @import("nav_key.zig").NavKey;
const typeahead = @import("typeahead.zig");

pub fn key(gpa: Allocator, tab: *Tab, opts: Opts, k: NavKey, shift: bool) Allocator.Error!void {
    const items = tab.exp.items;
    if (items.len == 0) return;
    const n = items.len;
    const lead = tab.selection.leadIndex(items);
    const target: usize = switch (k) {
        .up => if (lead) |l| l -| 1 else n - 1,
        .down => if (lead) |l| @min(l + 1, n - 1) else 0,
        .home => 0,
        .end => n - 1,
        .right => {
            const l = lead orelse return;
            if (!items[l].is_directory) return;
            if (!tab.exp.isExpanded(items[l].path)) return tab.setExpanded(items[l].path, true, opts);
            if (l + 1 < n and tab.exp.depth[l + 1] > tab.exp.depth[l]) return moveTo(gpa, tab, l + 1, false);
            return;
        },
        .left => {
            const l = lead orelse return;
            if (items[l].is_directory and tab.exp.isExpanded(items[l].path)) return tab.setExpanded(items[l].path, false, opts);
            const parent = std.fs.path.dirname(items[l].path) orelse return;
            if (tab.exp.depth[l] == 0) return;
            const p = tab.exp.indexOf(parent) orelse return;
            return moveTo(gpa, tab, p, false);
        },
    };
    try moveTo(gpa, tab, target, shift);
}

fn moveTo(gpa: Allocator, tab: *Tab, index: usize, extend: bool) Allocator.Error!void {
    try tab.selection.moveTo(gpa, tab.exp.items, index, extend);
    tab.reveal = index;
}

/// Selects the first row whose name starts with `prefix`; false if there is none.
pub fn typeSelect(gpa: Allocator, tab: *Tab, prefix: []const u8) Allocator.Error!bool {
    const i = typeahead.find(tab.exp.items, prefix) orelse return false;
    try moveTo(gpa, tab, i, false);
    return true;
}
