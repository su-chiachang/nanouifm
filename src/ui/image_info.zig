//! A picture's size in pixels, read from the file's own header: PNG, GIF and JPEG, in pure Zig
//! (no ImageIO), through libc `open` / `pread` / `close`. The inspector's "Resolution" row asks
//! for it through `Hooks.image_size`, whose default is `fromFile`; tests may put a fake there.
//! EXIF orientation is not applied (a portrait photo taken sideways reads as stored).
const std = @import("std");
const fs = @import("../core/file_ops_fs.zig");

pub const Dims = struct { w: u32, h: u32 };

/// The signature of the provider: null when the file is not a picture this reads.
pub const ReadFn = *const fn (path: []const u8) ?Dims;

/// Segments of a JPEG looked at before giving up (a real file has a dozen).
const max_segments = 512;

/// The dimensions of the picture in `path`, or null (missing file, another format, damaged header).
pub fn fromFile(path: []const u8) ?Dims {
    var b: [fs.path_max]u8 = undefined;
    const zp = fs.z(&b, path) orelse return null;
    const fd = std.c.open(zp, @bitCast(@as(u32, 0))); // O_RDONLY
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    return dims(FdReader{ .fd = fd });
}

/// The dimensions of a picture held in memory (a prefix of the file is enough for PNG and GIF).
pub fn fromBytes(bytes: []const u8) ?Dims {
    return dims(BytesReader{ .bytes = bytes });
}

const FdReader = struct {
    fd: std.c.fd_t,

    fn readAt(self: FdReader, off: u64, buf: []u8) usize {
        const n = std.c.pread(self.fd, buf.ptr, buf.len, @intCast(off));
        return if (n < 0) 0 else @intCast(n);
    }
};

const BytesReader = struct {
    bytes: []const u8,

    fn readAt(self: BytesReader, off: u64, buf: []u8) usize {
        if (off >= self.bytes.len) return 0;
        const n = @min(buf.len, self.bytes.len - @as(usize, @intCast(off)));
        @memcpy(buf[0..n], self.bytes[@intCast(off)..][0..n]);
        return n;
    }
};

fn dims(r: anytype) ?Dims {
    var head: [24]u8 = undefined;
    const n = r.readAt(0, &head);
    if (n >= 24 and std.mem.eql(u8, head[0..8], "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, head[12..16], "IHDR")) {
        return nonZero(std.mem.readInt(u32, head[16..20], .big), std.mem.readInt(u32, head[20..24], .big));
    }
    if (n >= 10 and (std.mem.eql(u8, head[0..6], "GIF87a") or std.mem.eql(u8, head[0..6], "GIF89a"))) {
        return nonZero(std.mem.readInt(u16, head[6..8], .little), std.mem.readInt(u16, head[8..10], .little));
    }
    if (n >= 4 and head[0] == 0xFF and head[1] == 0xD8 and head[2] == 0xFF) return jpeg(r);
    return null;
}

fn nonZero(w: u32, h: u32) ?Dims {
    return if (w == 0 or h == 0) null else .{ .w = w, .h = h };
}

/// Walks the JPEG's segments (by their lengths, so a large EXIF block is skipped, not read) to the
/// first start-of-frame, which carries the size.
fn jpeg(r: anytype) ?Dims {
    var pos: u64 = 2; // after SOI
    var seg: [9]u8 = undefined;
    var count: usize = 0;
    while (count < max_segments) : (count += 1) {
        // Find the next marker: 0xFF, then a code that is not 0x00 or another 0xFF (fill bytes).
        var two: [2]u8 = undefined;
        if (r.readAt(pos, &two) < 2) return null;
        if (two[0] != 0xFF) return null;
        if (two[1] == 0xFF) { // fill
            pos += 1;
            continue;
        }
        const code = two[1];
        pos += 2;
        if (code == 0x01 or (code >= 0xD0 and code <= 0xD8)) continue; // no length: TEM, RSTn, SOI
        if (code == 0xD9 or code == 0xDA) return null; // EOI, or the scan began without a frame
        var len_b: [2]u8 = undefined;
        if (r.readAt(pos, &len_b) < 2) return null;
        const len = std.mem.readInt(u16, &len_b, .big);
        if (len < 2) return null;
        const is_sof = code >= 0xC0 and code <= 0xCF and code != 0xC4 and code != 0xC8 and code != 0xCC;
        if (is_sof) {
            // length(2) precision(1) height(2) width(2)
            if (r.readAt(pos, &seg) < 7) return null;
            return nonZero(std.mem.readInt(u16, seg[5..7], .big), std.mem.readInt(u16, seg[3..5], .big));
        }
        pos += len;
    }
    return null;
}

/// "640 × 480".
pub fn label(buf: []u8, d: Dims) []const u8 {
    return std.fmt.bufPrint(buf, "{d} \u{00D7} {d}", .{ d.w, d.h }) catch "";
}

// ---- tests ----

const testing = std.testing;

/// A PNG's signature and IHDR (the rest is not needed to read the size).
pub fn pngHeader(w: u32, h: u32) [33]u8 {
    var b: [33]u8 = @splat(0);
    @memcpy(b[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, b[8..12], 13, .big);
    @memcpy(b[12..16], "IHDR");
    std.mem.writeInt(u32, b[16..20], w, .big);
    std.mem.writeInt(u32, b[20..24], h, .big);
    b[24] = 8; // bit depth
    b[25] = 2; // RGB
    return b;
}

/// A JPEG with an APP1 block of `app_len` filler bytes before the frame header.
pub fn jpegHeader(a: std.mem.Allocator, w: u16, h: u16, app_len: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, &.{ 0xFF, 0xD8 });
    try out.appendSlice(a, &.{ 0xFF, 0xE1 });
    var l: [2]u8 = undefined;
    std.mem.writeInt(u16, &l, app_len + 2, .big);
    try out.appendSlice(a, &l);
    try out.appendNTimes(a, 'E', app_len);
    try out.appendSlice(a, &.{ 0xFF, 0xC4, 0x00, 0x04, 0x00, 0x00 }); // a DHT first: not a frame
    try out.appendSlice(a, &.{ 0xFF, 0xC0, 0x00, 0x0B, 0x08 });
    var hw: [4]u8 = undefined;
    std.mem.writeInt(u16, hw[0..2], h, .big);
    std.mem.writeInt(u16, hw[2..4], w, .big);
    try out.appendSlice(a, &hw);
    try out.appendSlice(a, &.{ 0x01, 0x01, 0x11, 0x00 });
    return out.toOwnedSlice(a);
}

test "PNG, GIF and JPEG headers" {
    const png = pngHeader(640, 480);
    try testing.expectEqual(Dims{ .w = 640, .h = 480 }, fromBytes(&png).?);
    const gif = "GIF89a" ++ [_]u8{ 0x20, 0x00, 0x10, 0x00 } ++ "\x00\x00\x00";
    try testing.expectEqual(Dims{ .w = 32, .h = 16 }, fromBytes(gif).?);
    const jpg = try jpegHeader(testing.allocator, 1920, 1080, 60_000); // an EXIF block far bigger than a header buffer
    defer testing.allocator.free(jpg);
    try testing.expectEqual(Dims{ .w = 1920, .h = 1080 }, fromBytes(jpg).?);
}

test "other data and damaged headers are not pictures" {
    try testing.expect(fromBytes("") == null);
    try testing.expect(fromBytes("just some text, long enough to have a header") == null);
    const png = pngHeader(0, 5);
    try testing.expect(fromBytes(&png) == null); // zero width
    try testing.expect(fromBytes(png[0..20]) == null); // cut short
    try testing.expect(fromBytes(&.{ 0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02 }) == null); // a scan with no frame
    try testing.expect(fromBytes(&.{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01 }) == null); // a length below 2
}

test "a missing file is not a picture" {
    try testing.expect(fromFile("/no/such/picture.png") == null);
}

test "labels" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("640 \u{00D7} 480", label(&b, .{ .w = 640, .h = 480 }));
}
