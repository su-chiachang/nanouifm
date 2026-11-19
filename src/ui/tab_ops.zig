//! Tab operations on the model (the Swift app's PaneViewController/AppModel glue around
//! `PaneModel`): a new tab in the focused pane, closing (a pane's last tab closes the pane, the
//! last pane's last tab stays), selecting and moving. Tabs are named by `TabRef` ids; one that
//! is gone is ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const TabRef = model_mod.TabRef;
const layout_ops = @import("layout_ops.zig");

/// Cmd+T and the "+" button: a tab in the same folder, right after the shown one, selected.
pub fn newTab(m: *Model) Allocator.Error!void {
    const pane = m.focusedPane();
    _ = try pane.addTabWith(pane.tab().path(), m.nextId(), m.opts(pane), null, true);
}

/// Cmd-click in the sidebar: `folder` in a new selected tab of the focused pane.
pub fn openInNewTab(m: *Model, folder: []const u8) Allocator.Error!void {
    const path = try model_mod.normalize(m.gpa, folder);
    defer m.gpa.free(path);
    const pane = m.focusedPane();
    _ = try pane.addTabWith(path, m.nextId(), m.opts(pane), null, true);
    m.clearNotice();
}

/// Closes a tab. The pane's last tab closes the pane, unless it is the last pane.
pub fn closeTab(m: *Model, ref: TabRef) Allocator.Error!void {
    const pi = m.paneIndex(ref.pane) orelse return;
    const pane = &m.panes.items[pi];
    const ti = pane.indexOfTab(ref.tab) orelse return;
    m.focused = pi;
    if (pane.tabs.items.len > 1) {
        try m.retired_tabs.ensureUnusedCapacity(m.gpa, 1);
        m.retired_tabs.appendAssumeCapacity(pane.closeTab(ti).?);
    } else if (m.panes.items.len > 1) {
        try layout_ops.closePane(m, pi);
    }
}

/// Cmd+W: the focused pane's shown tab.
pub fn closeActiveTab(m: *Model) Allocator.Error!void {
    const pane = m.focusedPane();
    try closeTab(m, .{ .pane = pane.id, .tab = pane.tab().id });
}

/// Shows a tab, and focuses its pane.
pub fn selectTab(m: *Model, ref: TabRef) void {
    const pi = m.paneIndex(ref.pane) orelse return;
    const pane = &m.panes.items[pi];
    const ti = pane.indexOfTab(ref.tab) orelse return;
    m.focused = pi;
    pane.selectTab(ti);
}

/// Moves a tab to slot `to` of its pane (a drag along the strip); the shown tab stays shown.
pub fn moveTab(m: *Model, ref: TabRef, to: u32) void {
    const pi = m.paneIndex(ref.pane) orelse return;
    const pane = &m.panes.items[pi];
    const from = pane.indexOfTab(ref.tab) orelse return;
    pane.moveTab(from, @min(to, pane.tabs.items.len - 1));
}
