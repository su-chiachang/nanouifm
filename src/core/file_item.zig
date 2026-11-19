//! FileItem, SortKey, SortOrder and the Finder-like name comparison (localizedStandardCompare emulation).

const std = @import("std");

/// Nanoseconds since the Unix epoch.
pub const Timestamp = i64;

pub const FileItem = struct {
    /// Full path, owned (see `deinit`). Also the item's identity.
    path: []const u8,
    /// Display name incl. extension; a slice into `path`.
    name: []const u8,
    /// True for real folders; packages (.app) are NOT directories here.
    is_directory: bool,
    is_package: bool,
    is_hidden: bool,
    is_symlink: bool,
    /// null for directories.
    size: ?i64,
    modified: ?Timestamp,
    created: ?Timestamp,
    /// Human description, e.g. "JPEG image", "Folder". Static or a slice into `buf`.
    kind: []const u8,
    /// The single allocation backing `path` (and a fallback `kind`, if any). Null for hand-built items.
    buf: ?[]u8 = null,

    pub fn deinit(self: FileItem, gpa: std.mem.Allocator) void {
        if (self.buf) |b| gpa.free(b);
    }

    /// Items are equal when they name the same path (id == path).
    pub fn eql(a: FileItem, b: FileItem) bool {
        return std.mem.eql(u8, a.path, b.path);
    }
};

pub const SortKey = enum { name, kind, size, modified, created };

pub const SortOrder = struct {
    key: SortKey = .name,
    ascending: bool = true,
    folders_first: bool = true,
};

// ---- Name comparison ----

const Cp = struct { cp: u21, len: usize };

fn decode(s: []const u8, i: usize) Cp {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .cp = s[i], .len = 1 };
    if (i + n > s.len) return .{ .cp = s[i], .len = 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ .cp = s[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn isDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

/// Simple case folding: ASCII, Latin-1, Greek and Cyrillic.
fn fold(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        0x391...0x3A1, 0x3A3...0x3A9 => cp + 32,
        0x410...0x42F => cp + 32,
        0x400...0x40F => cp + 80,
        else => cp,
    };
}

/// Symbols sort before digits, digits before letters (as in Finder).
fn rank(cp: u21) u8 {
    if (isDigit(cp)) return 1;
    if (cp >= 128) return 2;
    if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z')) return 2;
    return 0;
}

fn orderInt(a: anytype, b: anytype) std.math.Order {
    return std.math.order(a, b);
}

/// Case-insensitive, natural-numeric ("file2" < "file10"), symbols < digits < letters.
/// Case-only differences are a final tie-break (lowercase first), so equal names compare `.eq`.
pub fn compareNames(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = decode(a, i);
        const cb = decode(b, j);
        if (isDigit(ca.cp) and isDigit(cb.cp)) {
            var ie = i;
            while (ie < a.len and isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and isDigit(b[je])) je += 1;
            var ia = i;
            while (ia + 1 < ie and a[ia] == '0') ia += 1;
            var jb = j;
            while (jb + 1 < je and b[jb] == '0') jb += 1;
            const da = a[ia..ie];
            const db = b[jb..je];
            if (da.len != db.len) return orderInt(da.len, db.len);
            const o = std.mem.order(u8, da, db);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const fa = fold(ca.cp);
        const fb = fold(cb.cp);
        const ra = rank(fa);
        const rb = rank(fb);
        if (ra != rb) return orderInt(ra, rb);
        if (fa != fb) return orderInt(fa, fb);
        i += ca.len;
        j += cb.len;
    }
    if (i < a.len) return .gt;
    if (j < b.len) return .lt;
    return tieBreak(a, b);
}

fn tieBreak(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const ca = decode(a, i);
        const cb = decode(b, j);
        if (ca.cp != cb.cp) {
            // Same fold: the lowercase form comes first.
            if (fold(ca.cp) == fold(cb.cp)) return if (ca.cp == fold(ca.cp)) .lt else .gt;
            return orderInt(ca.cp, cb.cp);
        }
        i += ca.len;
        j += cb.len;
    }
    return std.mem.order(u8, a, b);
}

// ---- Item ordering ----

fn orderSign(o: std.math.Order) i32 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Direction-adjusted comparison where null always sorts last.
fn cmpOpt(comptime T: type, a: ?T, b: ?T, ascending: bool) i32 {
    if (a == null and b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (a.? == b.?) return 0;
    return if ((a.? < b.?) == ascending) -1 else 1;
}

fn primary(a: FileItem, b: FileItem, order: SortOrder) i32 {
    return switch (order.key) {
        .name => blk: {
            const c = orderSign(compareNames(a.name, b.name));
            break :blk if (order.ascending) c else -c;
        },
        .kind => blk: {
            const c = orderSign(compareNames(a.kind, b.kind));
            break :blk if (order.ascending) c else -c;
        },
        .size => cmpOpt(i64, a.size, b.size, order.ascending),
        .modified => cmpOpt(Timestamp, a.modified, b.modified, order.ascending),
        .created => cmpOpt(Timestamp, a.created, b.created, order.ascending),
    };
}

/// Strict "a before b". Ties on the primary key fall back to name (ascending); the sort being
/// stable keeps input order for anything still equal.
pub fn lessThan(order: SortOrder, a: FileItem, b: FileItem) bool {
    if (order.folders_first and a.is_directory != b.is_directory) return a.is_directory;
    var c = primary(a, b, order);
    if (c == 0 and order.key != .name) c = orderSign(compareNames(a.name, b.name));
    return c < 0;
}

// ---- Tests ----

const testing = std.testing;

test "natural numeric compare" {
    try testing.expectEqual(std.math.Order.lt, compareNames("file2", "file10"));
    try testing.expectEqual(std.math.Order.gt, compareNames("file10", "file2"));
    try testing.expectEqual(std.math.Order.lt, compareNames("file1.txt", "File2.txt"));
    try testing.expectEqual(std.math.Order.eq, compareNames("same", "same"));
    try testing.expectEqual(std.math.Order.lt, compareNames("a", "ab"));
    try testing.expectEqual(std.math.Order.lt, compareNames("Alpha", "beta"));
    try testing.expectEqual(std.math.Order.lt, compareNames("a", "A"));
    try testing.expectEqual(std.math.Order.lt, compareNames("img2 copy", "img10"));
    try testing.expectEqual(std.math.Order.lt, compareNames("a9", "a010"));
    try testing.expectEqual(std.math.Order.lt, compareNames("_x", "1x"));
    try testing.expectEqual(std.math.Order.lt, compareNames("1x", "ax"));
}

test "SortOrder defaults" {
    const o = SortOrder{};
    try testing.expectEqual(SortKey.name, o.key);
    try testing.expect(o.ascending and o.folders_first);
    try testing.expectEqual(@as(usize, 5), std.meta.fieldNames(SortKey).len);
}
