//! A pane's name filter (the toolbar's search field): the field's text, kept per pane, and where
//! it was last applied, so leaving that folder clears it, as Swift's `filterText` is cleared
//! when the shown tab's URL changes (a tab switch keeps it). What the text does to the rows is
//! `Listing.rebuild`'s `filter` (the list's top level, or the column view's active column); the
//! model side (apply, clear on navigation, focus) is `filter_ops.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const Tab = @import("tab.zig").Tab;

pub const Filter = struct {
    /// The field's text (on the C heap, like every nanoui text buffer).
    buf: ui.TextBuffer = .{},
    /// The tab and folder the text was last applied to (owned path).
    tab: u32 = 0,
    path: ?[]u8 = null,

    pub fn text(self: *const Filter) []const u8 {
        return self.buf.text();
    }

    pub fn isActive(self: *const Filter) bool {
        return self.buf.text().len > 0;
    }

    pub fn deinit(self: *Filter, gpa: Allocator) void {
        self.buf.deinit();
        if (self.path) |p| gpa.free(p);
        self.* = .{};
    }

    /// Remembers that the text applies to `tab`'s folder as it is now.
    pub fn mark(self: *Filter, gpa: Allocator, tab: *const Tab) Allocator.Error!void {
        const copy = try gpa.dupe(u8, tab.path());
        if (self.path) |p| gpa.free(p);
        self.path = copy;
        self.tab = tab.id;
    }

    /// The text is gone: forgets where it applied.
    pub fn unmark(self: *Filter, gpa: Allocator) void {
        if (self.path) |p| gpa.free(p);
        self.path = null;
        self.tab = 0;
    }
};
