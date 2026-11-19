//! The pane layout tree (port of PaneLayout.swift): leaves are panes, splits arrange
//! their children along an axis. Pure data, no UI.
//!
//! Ownership: a tree owns its split slices and its leaves. If `Leaf` declares `deinit(*Leaf, gpa)`
//! and/or `clone(*const Leaf, gpa) !Leaf` they are used for the leaves it owns; plain-data leaves
//! (ints, borrowed strings) need neither. `eql(*const Leaf, *const Leaf) bool` is used for leaf
//! equality when declared (else `std.meta.eql`, or `std.mem.eql` for `[]const u8`).
//! Every operation that returns a tree returns a fresh, independently owned one and only
//! borrows its arguments; free the result with `deinit(gpa)`.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SplitAxis = enum {
    /// Children laid out left to right.
    side_by_side,
    /// Children laid out top to bottom.
    stacked,

    /// The Swift Codable raw value ("sideBySide" | "stacked"), kept for on-disk compatibility.
    pub fn jsonName(self: SplitAxis) []const u8 {
        return switch (self) {
            .side_by_side => "sideBySide",
            .stacked => "stacked",
        };
    }

    pub fn fromJsonName(name: []const u8) ?SplitAxis {
        if (std.mem.eql(u8, name, "sideBySide")) return .side_by_side;
        if (std.mem.eql(u8, name, "stacked")) return .stacked;
        return null;
    }
};

pub const DockSide = enum {
    left,
    right,
    top,
    bottom,

    pub fn axis(self: DockSide) SplitAxis {
        return if (self == .left or self == .right) .side_by_side else .stacked;
    }

    /// True when the new pane goes before (left of / above) the target.
    pub fn leading(self: DockSide) bool {
        return self == .left or self == .top;
    }
};

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

fn leafDeinit(comptime Leaf: type, leaf: *Leaf, gpa: Allocator) void {
    if (comptime hasDecl(Leaf, "deinit")) leaf.deinit(gpa);
}

pub fn leafClone(comptime Leaf: type, leaf: *const Leaf, gpa: Allocator) Allocator.Error!Leaf {
    if (comptime hasDecl(Leaf, "clone")) return leaf.clone(gpa);
    return leaf.*;
}

fn leafEql(comptime Leaf: type, a: *const Leaf, b: *const Leaf) bool {
    if (comptime hasDecl(Leaf, "eql")) return Leaf.eql(a, b);
    if (comptime Leaf == []const u8) return std.mem.eql(u8, a.*, b.*);
    return std.meta.eql(a.*, b.*);
}

pub fn LayoutTree(comptime Leaf: type) type {
    return union(enum) {
        leaf: Leaf,
        split: Split,

        const Self = @This();

        pub const Split = struct {
            axis: SplitAxis,
            children: []Self,
        };

        /// A lone leaf (takes ownership of `l`).
        pub fn single(l: Leaf) Self {
            return .{ .leaf = l };
        }

        /// A split over `children` (takes ownership of the slice, which must come from `gpa`).
        /// Not normalized; see `normalized`.
        pub fn splitOf(axis: SplitAxis, children: []Self) Self {
            return .{ .split = .{ .axis = axis, .children = children } };
        }

        /// Builds a split by moving `children` into a new slice (takes ownership of each child).
        pub fn splitFrom(gpa: Allocator, axis: SplitAxis, children: []const Self) Allocator.Error!Self {
            return splitOf(axis, try gpa.dupe(Self, children));
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            switch (self.*) {
                .leaf => |*l| leafDeinit(Leaf, l, gpa),
                .split => |s| {
                    for (s.children) |*c| c.deinit(gpa);
                    gpa.free(s.children);
                },
            }
            self.* = undefined;
        }

        pub fn clone(self: *const Self, gpa: Allocator) Allocator.Error!Self {
            switch (self.*) {
                .leaf => |*l| return .{ .leaf = try leafClone(Leaf, l, gpa) },
                .split => |s| {
                    const kids = try gpa.alloc(Self, s.children.len);
                    var done: usize = 0;
                    errdefer {
                        for (kids[0..done]) |*k| k.deinit(gpa);
                        gpa.free(kids);
                    }
                    while (done < kids.len) : (done += 1) kids[done] = try s.children[done].clone(gpa);
                    return splitOf(s.axis, kids);
                },
            }
        }

        /// Structural equality (axes, shape and leaf equality).
        pub fn eql(a: *const Self, b: *const Self) bool {
            switch (a.*) {
                .leaf => |*la| switch (b.*) {
                    .leaf => |*lb| return leafEql(Leaf, la, lb),
                    .split => return false,
                },
                .split => |sa| switch (b.*) {
                    .leaf => return false,
                    .split => |sb| {
                        if (sa.axis != sb.axis or sa.children.len != sb.children.len) return false;
                        for (sa.children, sb.children) |*x, *y| if (!x.eql(y)) return false;
                        return true;
                    },
                },
            }
        }

        pub fn leafCount(self: *const Self) usize {
            return switch (self.*) {
                .leaf => 1,
                .split => |s| blk: {
                    var n: usize = 0;
                    for (s.children) |*c| n += c.leafCount();
                    break :blk n;
                },
            };
        }

        /// Appends the leaves in reading order (left to right / top to bottom, depth first) to `out`.
        /// The leaves are bitwise copies BORROWED from the tree (valid until the tree changes or is freed).
        pub fn collectLeaves(self: *const Self, gpa: Allocator, out: *std.ArrayList(Leaf)) Allocator.Error!void {
            switch (self.*) {
                .leaf => |l| try out.append(gpa, l),
                .split => |s| for (s.children) |*c| try c.collectLeaves(gpa, out),
            }
        }

        /// Leaves in reading order, borrowed from the tree. Free the slice with `gpa.free`.
        pub fn leaves(self: *const Self, gpa: Allocator) Allocator.Error![]Leaf {
            var out: std.ArrayList(Leaf) = .empty;
            errdefer out.deinit(gpa);
            try out.ensureTotalCapacityPrecise(gpa, self.leafCount());
            try self.collectLeaves(gpa, &out);
            return out.toOwnedSlice(gpa);
        }

        pub fn contains(self: *const Self, target: *const Leaf) bool {
            switch (self.*) {
                .leaf => |*l| return leafEql(Leaf, l, target),
                .split => |s| {
                    for (s.children) |*c| if (c.contains(target)) return true;
                    return false;
                },
            }
        }

        /// A tree of the same shape whose leaves are `f(ctx, &leaf)` (each owned by the new tree).
        /// `f: fn (ctx, *const Leaf) Allocator.Error!T`.
        pub fn map(self: *const Self, gpa: Allocator, comptime T: type, ctx: anytype, comptime f: anytype) Allocator.Error!LayoutTree(T) {
            const Out = LayoutTree(T);
            switch (self.*) {
                .leaf => |*l| return .{ .leaf = try f(ctx, l) },
                .split => |s| {
                    const kids = try gpa.alloc(Out, s.children.len);
                    var done: usize = 0;
                    errdefer {
                        for (kids[0..done]) |*k| k.deinit(gpa);
                        gpa.free(kids);
                    }
                    while (done < kids.len) : (done += 1) kids[done] = try s.children[done].map(gpa, T, ctx, f);
                    return Out.splitOf(s.axis, kids);
                },
            }
        }

        /// Keeps the leaves for which `f(ctx, &leaf)` returns non-null (replacing them with the
        /// result, owned by the new tree); the result is normalized. null when no leaf survives.
        pub fn compactMapLeaves(self: *const Self, gpa: Allocator, comptime T: type, ctx: anytype, comptime f: anytype) Allocator.Error!?LayoutTree(T) {
            const Out = LayoutTree(T);
            switch (self.*) {
                .leaf => |*l| return if (try f(ctx, l)) |v| Out{ .leaf = v } else null,
                .split => |s| {
                    var kept: std.ArrayList(Out) = .empty;
                    errdefer {
                        for (kept.items) |*k| k.deinit(gpa);
                        kept.deinit(gpa);
                    }
                    for (s.children) |*c| {
                        if (try c.compactMapLeaves(gpa, T, ctx, f)) |k| {
                            errdefer {
                                var kk = k;
                                kk.deinit(gpa);
                            }
                            try kept.append(gpa, k);
                        }
                    }
                    return try Out.collapse(gpa, s.axis, try kept.toOwnedSlice(gpa));
                },
            }
        }

        /// Takes ownership of `kids` (a `gpa` slice of already-normalized, non-null trees) and returns the
        /// split over them with same-axis children flattened in, a lone child collapsed to itself, and
        /// null for none. Only one allocation can fail; on failure `kids` is freed.
        fn collapse(gpa: Allocator, axis: SplitAxis, kids: []Self) Allocator.Error!?Self {
            var total: usize = 0;
            for (kids) |k| total += switch (k) {
                .split => |s| if (s.axis == axis) s.children.len else 1,
                .leaf => 1,
            };
            if (total == 0) {
                gpa.free(kids);
                return null;
            }
            const out = gpa.alloc(Self, total) catch |e| {
                for (kids) |*k| k.deinit(gpa);
                gpa.free(kids);
                return e;
            };
            var i: usize = 0;
            for (kids) |k| {
                switch (k) {
                    .split => |s| if (s.axis == axis) {
                        @memcpy(out[i..][0..s.children.len], s.children);
                        i += s.children.len;
                        gpa.free(s.children);
                        continue;
                    },
                    .leaf => {},
                }
                out[i] = k;
                i += 1;
            }
            gpa.free(kids);
            if (total == 1) {
                const only = out[0];
                gpa.free(out);
                return only;
            }
            return splitOf(axis, out);
        }

        /// Collapses single-child splits, flattens same-axis nesting, drops empty splits.
        /// Returns a normalized copy; null when nothing is left.
        pub fn normalized(self: *const Self, gpa: Allocator) Allocator.Error!?Self {
            switch (self.*) {
                .leaf => return try self.clone(gpa),
                .split => |s| {
                    var kept: std.ArrayList(Self) = .empty;
                    errdefer {
                        for (kept.items) |*k| k.deinit(gpa);
                        kept.deinit(gpa);
                    }
                    for (s.children) |*c| {
                        if (try c.normalized(gpa)) |k| {
                            errdefer {
                                var kk = k;
                                kk.deinit(gpa);
                            }
                            try kept.append(gpa, k);
                        }
                    }
                    return try collapse(gpa, s.axis, try kept.toOwnedSlice(gpa));
                },
            }
        }

        /// A copy with `new` (cloned in; the caller keeps ownership of its own) docked next to `target`
        /// on `side`. A same-axis parent gets a sibling; otherwise the target is wrapped in a new split.
        /// Only the target's direct parent is considered. No match gives an unchanged copy.
        pub fn docking(self: *const Self, gpa: Allocator, new: *const Leaf, target: *const Leaf, side: DockSide) Allocator.Error!Self {
            switch (self.*) {
                .leaf => |*l| {
                    if (!leafEql(Leaf, l, target)) return self.clone(gpa);
                    const kids = try gpa.alloc(Self, 2);
                    var done: usize = 0;
                    errdefer {
                        for (kids[0..done]) |*k| k.deinit(gpa);
                        gpa.free(kids);
                    }
                    const new_node: Self = .{ .leaf = new.* };
                    const first: *const Self = if (side.leading()) &new_node else self;
                    const second: *const Self = if (side.leading()) self else &new_node;
                    kids[0] = try first.clone(gpa);
                    done = 1;
                    kids[1] = try second.clone(gpa);
                    done = 2;
                    return splitOf(side.axis(), kids);
                },
                .split => |s| {
                    if (s.axis == side.axis()) {
                        for (s.children, 0..) |*c, idx| {
                            const hit = switch (c.*) {
                                .leaf => |*l| leafEql(Leaf, l, target),
                                .split => false,
                            };
                            if (!hit) continue;
                            const at = if (side.leading()) idx else idx + 1;
                            const kids = try gpa.alloc(Self, s.children.len + 1);
                            var done: usize = 0;
                            errdefer {
                                for (kids[0..done]) |*k| k.deinit(gpa);
                                gpa.free(kids);
                            }
                            var src: usize = 0;
                            while (done < kids.len) : (done += 1) {
                                if (done == at) {
                                    const n: Self = .{ .leaf = new.* };
                                    kids[done] = try n.clone(gpa);
                                } else {
                                    kids[done] = try s.children[src].clone(gpa);
                                    src += 1;
                                }
                            }
                            return splitOf(s.axis, kids);
                        }
                    }
                    const kids = try gpa.alloc(Self, s.children.len);
                    var done: usize = 0;
                    errdefer {
                        for (kids[0..done]) |*k| k.deinit(gpa);
                        gpa.free(kids);
                    }
                    while (done < kids.len) : (done += 1) kids[done] = try s.children[done].docking(gpa, new, target, side);
                    return splitOf(s.axis, kids);
                },
            }
        }

        /// Tree without `target` (normalized); null if nothing is left.
        pub fn removing(self: *const Self, gpa: Allocator, target: *const Leaf) Allocator.Error!?Self {
            const Ctx = struct {
                gpa: Allocator,
                target: *const Leaf,
                fn keep(c: @This(), l: *const Leaf) Allocator.Error!?Leaf {
                    if (leafEql(Leaf, l, c.target)) return null;
                    return try leafClone(Leaf, l, c.gpa);
                }
            };
            return self.compactMapLeaves(gpa, Leaf, Ctx{ .gpa = gpa, .target = target }, Ctx.keep);
        }
    };
}

/// Whether two trees (possibly over different leaf types) have the same split structure.
pub fn sameShape(a: anytype, b: anytype) bool {
    switch (a.*) {
        .leaf => switch (b.*) {
            .leaf => return true,
            .split => return false,
        },
        .split => |sa| switch (b.*) {
            .leaf => return false,
            .split => |sb| {
                if (sa.axis != sb.axis or sa.children.len != sb.children.len) return false;
                for (sa.children, sb.children) |*x, *y| if (!sameShape(x, y)) return false;
                return true;
            },
        },
    }
}

// ---- tests (port of PaneLayoutTests) ----

const testing = std.testing;
const Tree = LayoutTree(u32);

fn lf(v: u32) Tree {
    return .{ .leaf = v };
}

fn row(gpa: Allocator, ids: []const u32) !Tree {
    return rowOrCol(gpa, .side_by_side, ids);
}

fn rowOrCol(gpa: Allocator, axis: SplitAxis, ids: []const u32) !Tree {
    const kids = try gpa.alloc(Tree, ids.len);
    for (ids, kids) |id, *k| k.* = lf(id);
    return Tree.splitOf(axis, kids);
}

fn mk(gpa: Allocator, axis: SplitAxis, kids: []const Tree) !Tree {
    return Tree.splitFrom(gpa, axis, kids);
}

fn expectLeaves(t: *const Tree, expected: []const u32) !void {
    const got = try t.leaves(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u32, expected, got);
}

fn expectTree(expected: Tree, actual: ?Tree) !void {
    var a = actual orelse return error.TestUnexpectedNull;
    defer a.deinit(testing.allocator);
    var e = expected;
    defer e.deinit(testing.allocator);
    try testing.expect(e.eql(&a));
}

test "dock on all sides of a root leaf" {
    const gpa = testing.allocator;
    const one = lf(1);
    const cases = [_]struct { side: DockSide, axis: SplitAxis, order: [2]u32 }{
        .{ .side = .left, .axis = .side_by_side, .order = .{ 2, 1 } },
        .{ .side = .right, .axis = .side_by_side, .order = .{ 1, 2 } },
        .{ .side = .top, .axis = .stacked, .order = .{ 2, 1 } },
        .{ .side = .bottom, .axis = .stacked, .order = .{ 1, 2 } },
    };
    for (cases) |c| {
        const got = try one.docking(gpa, &2, &1, c.side);
        try expectTree(try rowOrCol(gpa, c.axis, &c.order), got);
    }
}

test "same axis inserts a sibling" {
    const gpa = testing.allocator;
    var t = try row(gpa, &.{ 1, 2 });
    defer t.deinit(gpa);
    try expectTree(try row(gpa, &.{ 1, 3, 2 }), try t.docking(gpa, &3, &1, .right));
    try expectTree(try row(gpa, &.{ 3, 1, 2 }), try t.docking(gpa, &3, &1, .left));
    try expectTree(try row(gpa, &.{ 1, 2, 3 }), try t.docking(gpa, &3, &2, .right));
}

test "cross axis wraps the target inside a grid" {
    const gpa = testing.allocator;
    var grid = try mk(gpa, .stacked, &.{ try row(gpa, &.{ 1, 2 }), try row(gpa, &.{ 3, 4 }) });
    defer grid.deinit(gpa);

    var docked = try grid.docking(gpa, &9, &2, .bottom);
    defer docked.deinit(gpa);
    const row1 = try mk(gpa, .side_by_side, &.{ lf(1), try rowOrCol(gpa, .stacked, &.{ 2, 9 }) });
    try expectTree(try mk(gpa, .stacked, &.{ row1, try row(gpa, &.{ 3, 4 }) }), try docked.clone(gpa));
    try expectLeaves(&docked, &.{ 1, 2, 9, 3, 4 });

    // Docking only looks at the target's direct parent: top of leaf 3 wraps it within its row.
    const row2 = try mk(gpa, .side_by_side, &.{ try rowOrCol(gpa, .stacked, &.{ 9, 3 }), lf(4) });
    try expectTree(try mk(gpa, .stacked, &.{ try row(gpa, &.{ 1, 2 }), row2 }), try grid.docking(gpa, &9, &3, .top));
}

test "remove collapses and flattens" {
    const gpa = testing.allocator;
    var t = try mk(gpa, .side_by_side, &.{ lf(1), try rowOrCol(gpa, .stacked, &.{ 2, 3 }) });
    defer t.deinit(gpa);
    try expectTree(try row(gpa, &.{ 1, 2 }), try t.removing(gpa, &3));
    try expectTree(try rowOrCol(gpa, .stacked, &.{ 2, 3 }), try t.removing(gpa, &1));

    // Removing the only stacked sibling next to a same-axis parent flattens.
    const inner = try row(gpa, &.{ 2, 3 });
    const stacked = try mk(gpa, .stacked, &.{ inner, lf(4) });
    var nested = try mk(gpa, .side_by_side, &.{ lf(1), stacked });
    defer nested.deinit(gpa);
    try expectTree(try row(gpa, &.{ 1, 2, 3 }), try nested.removing(gpa, &4));

    const one = lf(1);
    try testing.expect((try one.removing(gpa, &1)) == null);
    var two = try row(gpa, &.{ 1, 2 });
    defer two.deinit(gpa);
    try expectTree(lf(1), try two.removing(gpa, &2));
    var empty = Tree.splitOf(.stacked, try gpa.alloc(Tree, 0));
    defer empty.deinit(gpa);
    try testing.expect((try empty.normalized(gpa)) == null);
}

test "normalized flattens same axis" {
    const gpa = testing.allocator;
    var t = try mk(gpa, .side_by_side, &.{
        try row(gpa, &.{ 1, 2 }),
        try rowOrCol(gpa, .stacked, &.{3}),
    });
    defer t.deinit(gpa);
    try expectTree(try row(gpa, &.{ 1, 2, 3 }), try t.normalized(gpa));
}

const DropTwo = struct {
    fn f(_: void, l: *const u32) Allocator.Error!?u32 {
        return if (l.* == 2) null else l.* * 10;
    }
    fn none(_: void, _: *const u32) Allocator.Error!?u32 {
        return null;
    }
};

test "compactMapLeaves drops leaves" {
    const gpa = testing.allocator;
    var t = try mk(gpa, .stacked, &.{ lf(1), try row(gpa, &.{ 2, 3 }) });
    defer t.deinit(gpa);
    try expectTree(try rowOrCol(gpa, .stacked, &.{ 10, 30 }), try t.compactMapLeaves(gpa, u32, {}, DropTwo.f));
    try testing.expect((try t.compactMapLeaves(gpa, u32, {}, DropTwo.none)) == null);
}

test "string leaves, map and sameShape" {
    const gpa = testing.allocator;
    const S = LayoutTree([]const u8);
    var s = try S.splitFrom(gpa, .side_by_side, &.{
        .{ .leaf = "a" },
        try S.splitFrom(gpa, .stacked, &.{ .{ .leaf = "b" }, .{ .leaf = "c" } }),
    });
    defer s.deinit(gpa);
    const Len = struct {
        fn f(_: void, l: *const []const u8) Allocator.Error!u32 {
            return @intCast(l.len);
        }
    };
    var lens = try s.map(gpa, u32, {}, Len.f);
    defer lens.deinit(gpa);
    try testing.expect(sameShape(&s, &lens));
    try testing.expectEqual(@as(usize, 3), lens.leafCount());
    try testing.expect(s.contains(&@as([]const u8, "c")));
    try testing.expect(!s.contains(&@as([]const u8, "z")));
    var other = try row(gpa, &.{ 1, 2 });
    defer other.deinit(gpa);
    try testing.expect(!sameShape(&s, &other));
}
