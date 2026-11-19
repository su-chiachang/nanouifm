//! Type-to-select: letters typed in quick succession build a prefix, and the first item whose
//! name starts with it is selected. There is no timer: each key carries the time it arrived at
//! (the frame's clock), and the prefix starts over when more than `reset_after` seconds passed
//! since the key before. Pure data.
const std = @import("std");
const FileItem = @import("../core/lister.zig").FileItem;

/// The pause, in seconds, after which the next key starts a new prefix.
pub const reset_after: f64 = 1.0;

pub const TypeAhead = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    /// When the last key arrived.
    last: f64 = 0,

    /// Adds the typed character (as AppKit names keys: lowercase) at time `now` and returns the
    /// prefix to look for. A space that would start a prefix is not a letter: empty back.
    pub fn feed(self: *TypeAhead, key: u21, now: f64) []const u8 {
        if (self.len > 0 and now - self.last > reset_after) self.len = 0;
        if (key == ' ' and self.len == 0) return "";
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key, &enc) catch return self.buf[0..self.len];
        if (self.len + n <= self.buf.len) {
            @memcpy(self.buf[self.len..][0..n], enc[0..n]);
            self.len += n;
        }
        self.last = now;
        return self.buf[0..self.len];
    }

    pub fn clear(self: *TypeAhead) void {
        self.len = 0;
    }
};

/// The first item whose name starts with `prefix`, ignoring case.
pub fn find(items: []const FileItem, prefix: []const u8) ?usize {
    if (prefix.len == 0) return null;
    for (items, 0..) |it, i| if (std.ascii.startsWithIgnoreCase(it.name, prefix)) return i;
    return null;
}

/// Whether a key (as `Shortcut.key` has it) is something to type-select with.
pub fn isTypeable(key: u21) bool {
    return (key >= 0x20 and key < 0x7f) or (key >= 0xA0 and key < 0xF700);
}

const testing = std.testing;

fn fake(name: []const u8) FileItem {
    return .{ .path = name, .name = name, .is_directory = false, .is_package = false, .is_hidden = false, .is_symlink = false, .size = 1, .modified = null, .created = null, .kind = "Document" };
}

test "the prefix grows within a second and starts over after a pause" {
    var t: TypeAhead = .{};
    try testing.expectEqualStrings("b", t.feed('b', 10.0));
    try testing.expectEqualStrings("bi", t.feed('i', 10.4));
    try testing.expectEqualStrings("big", t.feed('g', 11.3)); // 0.9 s after the last key
    try testing.expectEqualStrings("n", t.feed('n', 12.4)); // 1.1 s: fresh
    var fresh: TypeAhead = .{};
    try testing.expectEqualStrings("", fresh.feed(' ', 0));
}

test "find is case-insensitive and takes the first match" {
    const items = [_]FileItem{ fake("Apple"), fake("banana"), fake("Berry"), fake("cherry") };
    try testing.expectEqual(@as(?usize, 1), find(&items, "b"));
    try testing.expectEqual(@as(?usize, 2), find(&items, "BE"));
    try testing.expectEqual(@as(?usize, null), find(&items, "z"));
    try testing.expectEqual(@as(?usize, null), find(&items, ""));
    try testing.expect(isTypeable('a') and isTypeable('7') and !isTypeable(0xF700) and !isTypeable('\r'));
}
