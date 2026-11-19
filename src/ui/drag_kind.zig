//! What an in-window drag (nanoui's `dragSource` / `dropTarget`, whose payload is one u64) carries:
//! the pane whose selected rows are dragged (the payload is the pane's id), or a sidebar entry
//! being reordered (a tag bit, its section and its row). A drop target reads the kind first, so a
//! sidebar row asked about a pane's rows and a pane asked about an entry both ignore the other.
const std = @import("std");

const entry_bit: u64 = 1 << 40;

pub fn pane(id: u32) u64 {
    return id;
}

pub fn entry(section: usize, row: usize) u64 {
    return entry_bit | (@as(u64, @intCast(section)) << 20) | @as(u64, @intCast(row));
}

/// The pane id a payload names; null for an entry.
pub fn asPane(payload: u64) ?u32 {
    if (payload & entry_bit != 0) return null;
    return std.math.cast(u32, payload);
}

pub const Entry = struct { section: usize, row: usize };

pub fn asEntry(payload: u64) ?Entry {
    if (payload & entry_bit == 0) return null;
    return .{ .section = @intCast((payload >> 20) & 0xFFFFF), .row = @intCast(payload & 0xFFFFF) };
}

test "payload kinds don't mix" {
    try std.testing.expectEqual(@as(?u32, 7), asPane(pane(7)));
    try std.testing.expect(asEntry(pane(7)) == null);
    const e = asEntry(entry(2, 5)).?;
    try std.testing.expectEqual(@as(usize, 2), e.section);
    try std.testing.expectEqual(@as(usize, 5), e.row);
    try std.testing.expect(asPane(entry(2, 5)) == null);
}
