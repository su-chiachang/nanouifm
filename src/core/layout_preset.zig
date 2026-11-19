//! The 12 ready-made pane arrangements (port of LayoutPreset.swift). Each preset is a tree over
//! slot numbers 0..<slotCount, numbered in reading order, so applying one maps existing panes
//! onto slots in order.
const std = @import("std");
const Allocator = std.mem.Allocator;
const lt = @import("layout_tree.zig");
const LayoutTree = lt.LayoutTree;

pub const LayoutPreset = enum {
    single,
    two_columns,
    two_rows,
    three_columns,
    three_rows,
    /// One pane left, two stacked right.
    left_and_right_stack,
    /// Two stacked left, one pane right.
    left_stack_and_right,
    /// One pane on top, two side by side below.
    top_and_bottom_row,
    /// Two side by side on top, one pane below.
    top_row_and_bottom,
    grid_2x2,
    four_columns,
    four_rows,

    pub const all = std.enums.values(LayoutPreset);
    pub const Slots = LayoutTree(u32);

    /// The Swift raw value ("twoColumns", ...).
    pub fn rawName(self: LayoutPreset) []const u8 {
        return switch (self) {
            .single => "single",
            .two_columns => "twoColumns",
            .two_rows => "twoRows",
            .three_columns => "threeColumns",
            .three_rows => "threeRows",
            .left_and_right_stack => "leftAndRightStack",
            .left_stack_and_right => "leftStackAndRight",
            .top_and_bottom_row => "topAndBottomRow",
            .top_row_and_bottom => "topRowAndBottom",
            .grid_2x2 => "grid2x2",
            .four_columns => "fourColumns",
            .four_rows => "fourRows",
        };
    }

    /// Menu / command palette title.
    pub fn title(self: LayoutPreset) []const u8 {
        return switch (self) {
            .single => "Single Pane",
            .two_columns => "Two Columns",
            .two_rows => "Two Rows",
            .three_columns => "Three Columns",
            .three_rows => "Three Rows",
            .left_and_right_stack => "One Left, Two Right",
            .left_stack_and_right => "Two Left, One Right",
            .top_and_bottom_row => "One Top, Two Bottom",
            .top_row_and_bottom => "Two Top, One Bottom",
            .grid_2x2 => "2 \u{00D7} 2 Grid",
            .four_columns => "Four Columns",
            .four_rows => "Four Rows",
        };
    }

    pub fn slotCount(self: LayoutPreset) usize {
        return switch (self) {
            .single => 1,
            .two_columns, .two_rows => 2,
            .three_columns, .three_rows, .left_and_right_stack, .left_stack_and_right, .top_and_bottom_row, .top_row_and_bottom => 3,
            .grid_2x2, .four_columns, .four_rows => 4,
        };
    }

    fn line(gpa: Allocator, axis: lt.SplitAxis, first: u32, n: u32) Allocator.Error!Slots {
        const kids = try gpa.alloc(Slots, n);
        for (kids, 0..) |*k, i| k.* = .{ .leaf = first + @as(u32, @intCast(i)) };
        return Slots.splitOf(axis, kids);
    }

    fn pair(gpa: Allocator, axis: lt.SplitAxis, a: Slots, b: Slots) Allocator.Error!Slots {
        return Slots.splitFrom(gpa, axis, &.{ a, b });
    }

    /// Slot tree; leaves are slot indices in reading order. Free with `deinit(gpa)`.
    pub fn shape(self: LayoutPreset, gpa: Allocator) Allocator.Error!Slots {
        const sbs: lt.SplitAxis = .side_by_side;
        const stk: lt.SplitAxis = .stacked;
        switch (self) {
            .single => return .{ .leaf = 0 },
            .two_columns => return line(gpa, sbs, 0, 2),
            .two_rows => return line(gpa, stk, 0, 2),
            .three_columns => return line(gpa, sbs, 0, 3),
            .three_rows => return line(gpa, stk, 0, 3),
            .four_columns => return line(gpa, sbs, 0, 4),
            .four_rows => return line(gpa, stk, 0, 4),
            .left_and_right_stack => {
                var b = try line(gpa, stk, 1, 2);
                errdefer b.deinit(gpa);
                return pair(gpa, sbs, .{ .leaf = 0 }, b);
            },
            .left_stack_and_right => {
                var a = try line(gpa, stk, 0, 2);
                errdefer a.deinit(gpa);
                return pair(gpa, sbs, a, .{ .leaf = 2 });
            },
            .top_and_bottom_row => {
                var b = try line(gpa, sbs, 1, 2);
                errdefer b.deinit(gpa);
                return pair(gpa, stk, .{ .leaf = 0 }, b);
            },
            .top_row_and_bottom => {
                var a = try line(gpa, sbs, 0, 2);
                errdefer a.deinit(gpa);
                return pair(gpa, stk, a, .{ .leaf = 2 });
            },
            .grid_2x2 => {
                var a = try line(gpa, sbs, 0, 2);
                errdefer a.deinit(gpa);
                const b = try line(gpa, sbs, 2, 2);
                return pair(gpa, stk, a, b);
            },
        }
    }

    pub const ArrangeError = Allocator.Error || error{WrongPaneCount};

    /// The tree with `panes` (reading order) filling the slots; leaves are cloned.
    /// `panes.len` must equal `slotCount`.
    pub fn arranged(self: LayoutPreset, gpa: Allocator, comptime Leaf: type, panes: []const Leaf) ArrangeError!LayoutTree(Leaf) {
        if (panes.len != self.slotCount()) return error.WrongPaneCount;
        var s = try self.shape(gpa);
        defer s.deinit(gpa);
        const Ctx = struct {
            gpa: Allocator,
            panes: []const Leaf,
            fn f(c: @This(), slot: *const u32) Allocator.Error!Leaf {
                return lt.leafClone(Leaf, &c.panes[slot.*], c.gpa);
            }
        };
        return s.map(gpa, Leaf, Ctx{ .gpa = gpa, .panes = panes }, Ctx.f);
    }

    /// The preset whose shape equals `tree`'s shape (a pointer to any `LayoutTree`), if any.
    pub fn matching(gpa: Allocator, tree: anytype) Allocator.Error!?LayoutPreset {
        for (all) |p| {
            var s = try p.shape(gpa);
            defer s.deinit(gpa);
            if (lt.sameShape(&s, tree)) return p;
        }
        return null;
    }
};

/// How the panes of the current layout carry over to a preset.
pub fn PresetPlan(comptime Leaf: type) type {
    return struct {
        /// Existing panes that fill the slots, in reading order (borrowed from `current`).
        kept: []const Leaf,
        /// Panes that no longer have a slot; the caller closes them and appends their tabs
        /// to the last pane of the new arrangement (borrowed from `current`).
        dropped: []const Leaf,
        /// Number of brand-new panes to create for the remaining slots (open at the focused pane's folder).
        created: usize,

        pub fn make(current: []const Leaf, preset: LayoutPreset) @This() {
            const slots = preset.slotCount();
            const k = @min(slots, current.len);
            return .{ .kept = current[0..k], .dropped = current[k..], .created = slots -| current.len };
        }
    };
}

// ---- tests (port of LayoutPresetTests) ----

const testing = std.testing;

test "slot counts and unique shapes" {
    const gpa = testing.allocator;
    const expected = [_]usize{ 1, 2, 2, 3, 3, 3, 3, 3, 3, 4, 4, 4 };
    try testing.expectEqual(@as(usize, 12), LayoutPreset.all.len);
    for (LayoutPreset.all, expected) |p, n| {
        try testing.expectEqual(n, p.slotCount());
        var s = try p.shape(gpa);
        defer s.deinit(gpa);
        try testing.expectEqual(n, s.leafCount());
        const leaves = try s.leaves(gpa);
        defer gpa.free(leaves);
        for (leaves, 0..) |slot, i| try testing.expectEqual(@as(u32, @intCast(i)), slot); // reading order
        var norm = (try s.normalized(gpa)).?;
        defer norm.deinit(gpa);
        try testing.expect(s.eql(&norm)); // already normalized
        for (LayoutPreset.all) |q| {
            if (q == p) continue;
            var o = try q.shape(gpa);
            defer o.deinit(gpa);
            try testing.expect(!s.eql(&o));
        }
    }
}

test "arranged maps panes in order" {
    const gpa = testing.allocator;
    const S = LayoutTree([]const u8);
    var t = try LayoutPreset.left_and_right_stack.arranged(gpa, []const u8, &.{ "a", "b", "c" });
    defer t.deinit(gpa);
    var want = try S.splitFrom(gpa, .side_by_side, &.{
        .{ .leaf = "a" },
        try S.splitFrom(gpa, .stacked, &.{ .{ .leaf = "b" }, .{ .leaf = "c" } }),
    });
    defer want.deinit(gpa);
    try testing.expect(t.eql(&want));

    var g = try LayoutPreset.grid_2x2.arranged(gpa, u32, &.{ 1, 2, 3, 4 });
    defer g.deinit(gpa);
    const leaves = try g.leaves(gpa);
    defer gpa.free(leaves);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, leaves);
    try testing.expectError(error.WrongPaneCount, LayoutPreset.grid_2x2.arranged(gpa, u32, &.{ 1, 2 }));
}

test "matching ignores leaf identity" {
    const gpa = testing.allocator;
    const names = [_][]const u8{ "pane0", "pane1", "pane2", "pane3" };
    for (LayoutPreset.all) |p| {
        var t = try p.arranged(gpa, []const u8, names[0..p.slotCount()]);
        defer t.deinit(gpa);
        try testing.expectEqual(@as(?LayoutPreset, p), try LayoutPreset.matching(gpa, &t));
    }
    const T = LayoutTree(u32);
    const inner = try T.splitFrom(gpa, .side_by_side, &.{ .{ .leaf = 3 }, .{ .leaf = 4 } });
    const mid = try T.splitFrom(gpa, .stacked, &.{ .{ .leaf = 2 }, inner });
    var odd = try T.splitFrom(gpa, .side_by_side, &.{ .{ .leaf = 1 }, mid });
    defer odd.deinit(gpa);
    try testing.expectEqual(@as(?LayoutPreset, null), try LayoutPreset.matching(gpa, &odd));
}

test "plan grows and shrinks" {
    const P = PresetPlan(u32);
    const grow = P.make(&.{ 1, 2 }, .grid_2x2);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, grow.kept);
    try testing.expectEqual(@as(usize, 0), grow.dropped.len);
    try testing.expectEqual(@as(usize, 2), grow.created);

    const shrink = P.make(&.{ 1, 2, 3, 4 }, .two_rows);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, shrink.kept);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, shrink.dropped);
    try testing.expectEqual(@as(usize, 0), shrink.created);

    const same = P.make(&.{1}, .single);
    try testing.expectEqualSlices(u32, &.{1}, same.kept);
    try testing.expectEqual(@as(usize, 0), same.dropped.len);
    try testing.expectEqual(@as(usize, 0), same.created);
}
