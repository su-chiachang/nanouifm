//! Text for the list's columns: sizes ("1.5 MB") and dates ("Nov 19, 2026 at 3:04 PM").
//! Pure functions over a buffer; only `localOffset` asks the C library for the time zone.
const std = @import("std");

/// Like ByteCountFormatter (decimal units): "12 bytes", "1 KB", "1.5 MB", "12 MB".
pub fn size(buf: []u8, bytes: i64) []const u8 {
    const b: f64 = @floatFromInt(@max(bytes, 0));
    if (bytes < 0) return "--";
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, if (bytes == 1) "byte" else "bytes" }) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v = b / 1000.0;
    var u: usize = 0;
    while (v >= 999.5 and u + 1 < units.len) : (u += 1) v /= 1000.0;
    if (v < 10) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "";
}

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// `ns` (nanoseconds since the epoch) shifted by `offset_s` seconds east of UTC.
pub fn date(buf: []u8, ns: i64, offset_s: i64) []const u8 {
    const secs = @divFloor(ns, std.time.ns_per_s) + offset_s;
    if (secs < 0) return "--";
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const day = es.getDaySeconds();
    const h24: u8 = day.getHoursIntoDay();
    const h12: u8 = if (h24 % 12 == 0) 12 else h24 % 12;
    return std.fmt.bufPrint(buf, "{s} {d}, {d} at {d}:{d:0>2} {s}", .{
        month_names[@intCast(@backingInt(md.month) - 1)],
        @as(u8, md.day_index) + 1,
        yd.year,
        h12,
        day.getMinutesIntoHour(),
        if (h24 < 12) "AM" else "PM",
    }) catch "";
}

// libc's calendar time; macOS `struct tm`.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const std.c.time_t, out: *Tm) ?*Tm;

/// Seconds east of UTC the local time zone is at `ns` (0 if unknown).
pub fn localOffset(ns: i64) i64 {
    const t: std.c.time_t = @intCast(@divFloor(ns, std.time.ns_per_s));
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return 0;
    return tm.gmtoff;
}

/// The date as the local time zone shows it.
pub fn localDate(buf: []u8, ns: i64) []const u8 {
    return date(buf, ns, localOffset(ns));
}

const testing = std.testing;

test "sizes" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("0 bytes", size(&b, 0));
    try testing.expectEqualStrings("1 byte", size(&b, 1));
    try testing.expectEqualStrings("999 bytes", size(&b, 999));
    try testing.expectEqualStrings("1.0 KB", size(&b, 1000));
    try testing.expectEqualStrings("1.5 KB", size(&b, 1536));
    try testing.expectEqualStrings("12 KB", size(&b, 12_345));
    try testing.expectEqualStrings("1.5 MB", size(&b, 1_500_000));
    try testing.expectEqualStrings("2.0 GB", size(&b, 2_000_000_000));
}

test "dates" {
    var b: [48]u8 = undefined;
    // 2026-11-19 15:04:00 UTC
    const ns: i64 = 1_795_100_640 * std.time.ns_per_s;
    try testing.expectEqualStrings("Nov 19, 2026 at 3:04 PM", date(&b, ns, 0));
    try testing.expectEqualStrings("Nov 19, 2026 at 11:04 PM", date(&b, ns, 8 * 3600));
    try testing.expectEqualStrings("Jan 1, 1970 at 12:00 AM", date(&b, 0, 0));
}
