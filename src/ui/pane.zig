//! A pane: a strip of tabs, one of them shown. (Slice 1 has one pane with one tab.)
const std = @import("std");
const Allocator = std.mem.Allocator;
const Tab = @import("tab.zig").Tab;

pub const Pane = struct {
    gpa: Allocator,
    tabs: std.ArrayList(Tab) = .empty,
    active: usize = 0,

    /// A pane with one tab in `folder`.
    pub fn init(gpa: Allocator, folder: []const u8, show_hidden: bool) Allocator.Error!Pane {
        var p: Pane = .{ .gpa = gpa };
        errdefer p.deinit();
        var t = try Tab.init(gpa, folder, show_hidden);
        errdefer t.deinit();
        try p.tabs.append(gpa, t);
        return p;
    }

    pub fn deinit(self: *Pane) void {
        for (self.tabs.items) |*t| t.deinit();
        self.tabs.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn tab(self: *Pane) *Tab {
        return &self.tabs.items[self.active];
    }
};
