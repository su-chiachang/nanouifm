//! Names and path relations for file_ops.zig: validation, "name 2.ext" / "name copy 2.ext"
//! uniquifying, and the folder-into-itself / descendant checks. Paths are absolute UTF-8.
const std = @import("std");
const fs = @import("file_ops_fs.zig");

const Allocator = std.mem.Allocator;
pub const NameList = std.ArrayList([]const u8);

/// Rejects empty/blank names, "/" or ":" in a name, ".", "..", over 255 bytes, and NUL.
pub fn validName(name: []const u8) bool {
    if (std.mem.trim(u8, name, " \t\r\n").len == 0) return false;
    if (name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/:\x00") == null;
}

pub fn parentDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

pub fn leaf(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn join(a: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ dir, name });
}

pub const StemExt = struct { stem: []const u8, ext: []const u8 };

/// Splits "name.ext" at the last dot; a leading dot or a trailing dot is not an extension.
pub fn splitExt(name: []const u8) StemExt {
    const i = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ .stem = name, .ext = "" };
    if (i == 0 or i + 1 == name.len) return .{ .stem = name, .ext = "" };
    return .{ .stem = name[0..i], .ext = name[i..] };
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// "name 2.ext" (copy) or "name copy.ext" / "name copy 2.ext" (duplicate), the first free one in
/// `directory`. `reserved` holds the lowercased full paths already claimed by earlier items of the
/// same batch; the chosen one is added. Folders and packages do not split on dots.
pub fn uniqueDestination(a: Allocator, directory: []const u8, source: []const u8, duplicate: bool, reserved: *NameList) ![]u8 {
    const name = leaf(source);
    const parts: StemExt = if (fs.isRealDirectory(source)) .{ .stem = name, .ext = "" } else splitExt(name);
    var n: usize = 1;
    while (true) : (n += 1) {
        const base = if (!duplicate)
            (if (n == 1) try a.dupe(u8, parts.stem) else try std.fmt.allocPrint(a, "{s} {d}", .{ parts.stem, n }))
        else
            (if (n == 1) try std.fmt.allocPrint(a, "{s} copy", .{parts.stem}) else try std.fmt.allocPrint(a, "{s} copy {d}", .{ parts.stem, n }));
        const full_name = try std.fmt.allocPrint(a, "{s}{s}", .{ base, parts.ext });
        const candidate = try join(a, directory, full_name);
        const key = try std.ascii.allocLowerString(a, candidate);
        if (!fs.exists(candidate) and !contains(reserved.items, key)) {
            try reserved.append(a, key);
            return candidate;
        }
    }
}

// ---------------------------------------------------------------- containment

fn splitComponents(a: Allocator, path: []const u8, list: *NameList) !void {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| try list.append(a, p);
}

/// Components of `path` with its parent's symlinks resolved; the leaf is kept as is.
fn itemComponents(a: Allocator, path: []const u8) !NameList {
    var list: NameList = .empty;
    var rb: [fs.path_max]u8 = undefined;
    const parent = parentDir(path);
    try splitComponents(a, fs.realpath(&rb, parent) orelse parent, &list);
    // `rb` is on the stack: the components above point into it, so copy them.
    for (list.items) |*p| p.* = try a.dupe(u8, p.*);
    const l = leaf(path);
    if (l.len > 0) try list.append(a, l);
    return list;
}

/// True when `directory` is `item` itself or lives underneath it. A symlinked item is not the
/// folder it points at.
pub fn isInside(a: Allocator, directory: []const u8, item: []const u8) !bool {
    var d: NameList = .empty;
    var rb: [fs.path_max]u8 = undefined;
    const resolved = fs.realpath(&rb, directory) orelse directory;
    try splitComponents(a, resolved, &d);
    for (d.items) |*p| p.* = try a.dupe(u8, p.*);
    const s = try itemComponents(a, item);
    if (d.items.len < s.items.len) return false;
    for (s.items, 0..) |part, i| if (!std.mem.eql(u8, part, d.items[i])) return false;
    return true;
}

/// Removes duplicates and any item that lies inside another item of the list (trashing the
/// parent already takes it along). Input order is kept.
pub fn dropDescendants(a: Allocator, urls: []const []const u8) ![]const []const u8 {
    var comps: std.ArrayList(NameList) = .empty;
    var keep: std.ArrayList(usize) = .empty;
    for (urls) |u| try comps.append(a, try itemComponents(a, u));
    outer: for (urls, 0..) |_, i| {
        for (0..i) |j| if (sameComps(comps.items[j].items, comps.items[i].items)) continue :outer;
        try keep.append(a, i);
    }
    var out: std.ArrayList([]const u8) = .empty;
    outer2: for (keep.items) |i| {
        for (keep.items) |j| {
            const o = comps.items[j].items;
            const c = comps.items[i].items;
            if (o.len < c.len and sameComps(o, c[0..o.len])) continue :outer2;
        }
        try out.append(a, urls[i]);
    }
    return out.items;
}

fn sameComps(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

test "splitExt and validName" {
    try std.testing.expectEqualStrings(".txt", splitExt("a.txt").ext);
    try std.testing.expectEqualStrings("a.tar", splitExt("a.tar.gz").stem);
    try std.testing.expectEqualStrings("", splitExt(".bashrc").ext);
    try std.testing.expectEqualStrings("", splitExt("trail.").ext);
    try std.testing.expect(validName("a b.txt"));
    for ([_][]const u8{ "", "   ", "x/y", "x:y", ".", "..", "a\x00b" }) |bad| try std.testing.expect(!validName(bad));
    const long: [256]u8 = @splat('x');
    try std.testing.expect(!validName(&long));
    try std.testing.expect(validName(long[0..255]));
}
