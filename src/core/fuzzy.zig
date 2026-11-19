//! Fuzzy filename scoring: a port of nanofmCore's FuzzyMatcher.
//!
//! `score` is a case-insensitive subsequence match; higher is better. Bonuses: prefix,
//! word boundary (after any non-alphanumeric, e.g. `/ - _ . space`), camelCase hump and
//! consecutive runs; shorter candidates win ties. `null` means no match.
//!
//! Characters are Unicode code points (the Swift original used grapheme clusters). Case
//! folding covers ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic. Input beyond
//! `max_candidate` / `max_query` code points is ignored (names are at most 255 bytes).

const std = @import("std");

pub const max_candidate = 512;
pub const max_query = 128;

const neg_inf: i64 = std.math.minInt(i64) / 4;

/// `null` = no match. An empty (or all-whitespace) query matches everything with score 0.
pub fn score(query: []const u8, candidate: []const u8) ?i64 {
    var q_buf: [max_query]u21 = undefined;
    var m: usize = 0;
    var all_ascii = true;
    {
        var i: usize = 0;
        while (i < query.len and m < max_query) {
            const cp = decode(query, &i);
            if (isWhitespace(cp)) continue;
            const l = lower(cp);
            if (l >= 0x80) all_ascii = false;
            q_buf[m] = l;
            m += 1;
        }
    }
    if (m == 0) return 0;
    const q = q_buf[0..m];

    // Fast rejection for the common ASCII/ASCII case: no decoding, same subsequence semantics.
    if (all_ascii) {
        var qi: usize = 0;
        var ascii = true;
        for (candidate) |b| {
            if (b >= 0x80) {
                ascii = false;
                break;
            }
            const l: u21 = if (b >= 'A' and b <= 'Z') b | 0x20 else b;
            if (qi < m and l == q[qi]) qi += 1;
        }
        if (ascii and qi < m) return null;
    }

    var c_buf: [max_candidate]u21 = undefined;
    var cl_buf: [max_candidate]u21 = undefined;
    var n: usize = 0;
    {
        var i: usize = 0;
        while (i < candidate.len and n < max_candidate) {
            const cp = decode(candidate, &i);
            c_buf[n] = cp;
            cl_buf[n] = lower(cp);
            n += 1;
        }
    }
    if (m > n) return null;
    const c = c_buf[0..n];
    const cl = cl_buf[0..n];

    // Cheap subsequence rejection before running the DP.
    {
        var qi: usize = 0;
        for (cl) |ch| {
            if (qi < m and ch == q[qi]) qi += 1;
        }
        if (qi < m) return null;
    }

    const gap: i64 = 1;
    const consecutive_bonus: i64 = 15;
    var prev_buf: [max_candidate]i64 = undefined;
    var cur_buf: [max_candidate]i64 = undefined;
    var prev: []i64 = prev_buf[0..n];
    var cur: []i64 = cur_buf[0..n];
    @memset(prev, neg_inf);
    @memset(cur, neg_inf);

    for (0..m) |i| {
        if (i == 0) {
            for (0..n) |j| {
                cur[j] = if (cl[j] == q[0])
                    charScore(c, j, true) - @as(i64, @intCast(@min(j, 5)))
                else
                    neg_inf;
            }
        } else {
            var running_max: i64 = neg_inf; // max over k <= j-2 of prev[k] + k*gap
            for (0..n) |j| {
                cur[j] = neg_inf;
                if (j >= 2 and prev[j - 2] > neg_inf) {
                    running_max = @max(running_max, prev[j - 2] + @as(i64, @intCast(j - 2)) * gap);
                }
                if (cl[j] != q[i] or j < i) continue;
                var best: i64 = neg_inf;
                if (j >= 1 and prev[j - 1] > neg_inf) best = prev[j - 1] + consecutive_bonus;
                if (running_max > neg_inf) {
                    best = @max(best, running_max - @as(i64, @intCast(j)) * gap + gap);
                }
                if (best > neg_inf) cur[j] = best + charScore(c, j, false);
            }
        }
        std.mem.swap([]i64, &prev, &cur);
    }
    var total: i64 = neg_inf;
    for (prev) |v| total = @max(total, v);
    if (total <= neg_inf) return null;
    return total * 100 - @as(i64, @intCast(@min(n, 99)));
}

fn charScore(c: []const u21, j: usize, first_query_char: bool) i64 {
    var s: i64 = 10;
    if (j == 0) {
        s += 15;
        if (first_query_char) s += 25; // prefix match
    } else {
        const p = c[j - 1];
        const cur = c[j];
        if (!isLetterOrNumber(p)) {
            s += 15;
        } else if (isLowerCase(p) and isUpperCase(cur)) {
            s += 12; // camelCase hump
        }
    }
    return s;
}

/// Next code point at `i.*` (advancing it); invalid bytes decode as U+FFFD one byte at a time.
fn decode(s: []const u8, i: *usize) u21 {
    const b = s[i.*];
    if (b < 0x80) {
        i.* += 1;
        return b;
    }
    const len = std.unicode.utf8ByteSequenceLength(b) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > s.len) {
        i.* += 1;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(s[i.*..][0..len]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    i.* += len;
    return cp;
}

fn isWhitespace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

pub fn lower(c: u21) u21 {
    if (c < 0x80) return if (c >= 'A' and c <= 'Z') c | 0x20 else c;
    return switch (c) {
        0xC0...0xD6, 0xD8...0xDE => c + 0x20,
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => c | 1,
        0x139...0x148, 0x179...0x17E => if (c & 1 == 1) c + 1 else c,
        0x178 => 0xFF,
        0x391...0x3A1, 0x3A3...0x3A9 => c + 0x20,
        0x410...0x42F => c + 0x20,
        0x400...0x40F => c + 0x50,
        else => c,
    };
}

fn isUpperCase(c: u21) bool {
    return lower(c) != c;
}

fn isLowerCase(c: u21) bool {
    if (c < 0x80) return c >= 'a' and c <= 'z';
    return switch (c) {
        0xDF...0xF6, 0xF8...0xFF => true,
        0x100...0x17F => lower(c) == c,
        0x3B1...0x3C9, 0x430...0x45F => true,
        else => false,
    };
}

fn isLetterOrNumber(c: u21) bool {
    if (c < 0x80) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
    return switch (c) {
        0x80...0xA9, 0xAB...0xB1, 0xB4, 0xB6...0xB8, 0xBB, 0xBF, 0xD7, 0xF7 => false,
        0xFFFD => false,
        0x2000...0x206F, 0x20A0...0x20CF, 0x2190...0x2BFF => false, // punctuation, currency, arrows, symbols
        0x3000...0x3004, 0x3008...0x3020, 0xFF00...0xFF0F, 0xFF1A...0xFF20 => false, // CJK / fullwidth punctuation
        0x1F000...0x1FAFF => false, // emoji
        else => true,
    };
}

// ---------------------------------------------------------------------------- tests

const testing = std.testing;

fn sc(q: []const u8, c: []const u8) ?i64 {
    return score(q, c);
}

fn expectGreater(a: ?i64, b: ?i64) !void {
    try testing.expect(a != null and b != null);
    try testing.expect(a.? > b.?);
}

test "no match is null" {
    try testing.expectEqual(@as(?i64, null), sc("xyz", "Documents"));
    try testing.expectEqual(@as(?i64, null), sc("doc", "cod")); // order matters
    try testing.expectEqual(@as(?i64, null), sc("abcd", "abc")); // query longer than candidate
    try testing.expectEqual(@as(?i64, null), sc("aa", "a"));
}

test "ascii fast reject keeps semantics for non-ascii and case" {
    try testing.expect(sc("rsm", "R\u{00E9}sum\u{00E9}.txt") != null); // non-ASCII candidate still matches ASCII subsequence
    try testing.expectEqual(@as(?i64, null), sc("resume", "R\u{00E9}sum\u{00E9}.txt")); // e-acute is not 'e'
    try testing.expect(sc("\u{65E5}\u{672C}", "\u{65E5}\u{672C}\u{8A9E}.txt") != null);
    try testing.expect(sc("ABC", "xaXbXc") != null);
    try testing.expectEqual(@as(?i64, null), sc("abc", "ACB"));
    try testing.expect(sc("\u{00E9}", "\u{00C9}t\u{00E9}") != null); // case folding beyond ASCII
}

test "case insensitive subsequence" {
    try testing.expect(sc("DOC", "documents") != null);
    try testing.expect(sc("dcs", "Documents") != null);
    try testing.expectEqual(@as(?i64, 0), sc("", "anything"));
    try testing.expectEqual(@as(?i64, 0), sc("  \t", "anything"));
    try testing.expect(sc("d o c", "documents") != null); // whitespace in the query is ignored
}

test "prefix beats mid word" {
    try expectGreater(sc("doc", "Documents"), sc("doc", "mydocs"));
}

test "word boundary beats scattered" {
    try expectGreater(sc("rp", "annual_report.pdf"), sc("rp", "carpet.txt"));
    try expectGreater(sc("fm", "FileManager"), sc("fm", "formal.txt"));
    try expectGreater(sc("nt", "my-notes"), sc("nt", "monument"));
}

test "consecutive runs beat gaps" {
    try expectGreater(sc("note", "a_notes"), sc("note", "a_nxoxtxe"));
}

test "shorter candidate wins ties" {
    try expectGreater(sc("doc", "docs"), sc("doc", "docsandmore"));
    try expectGreater(sc("readme", "readme"), sc("readme", "readme.md"));
}

test "ranking order" {
    const candidates = [_][]const u8{ "Downloads", "Documents", "doc.txt", "my_doc_notes.txt", "undocumented", "d-o-c" };
    const Item = struct { name: []const u8, score: i64 };
    var items: [candidates.len]Item = undefined;
    var count: usize = 0;
    for (candidates) |cand| {
        if (sc("doc", cand)) |val| {
            items[count] = .{ .name = cand, .score = val };
            count += 1;
        }
    }
    std.mem.sort(Item, items[0..count], {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return a.score > b.score;
        }
    }.lt);
    const ranked = items[0..count];
    try testing.expectEqualStrings("doc.txt", ranked[0].name);
    const idx = struct {
        fn of(r: []const Item, name: []const u8) usize {
            for (r, 0..) |it, i| if (std.mem.eql(u8, it.name, name)) return i;
            return std.math.maxInt(usize);
        }
    }.of;
    try testing.expect(idx(ranked, "Documents") < idx(ranked, "my_doc_notes.txt"));
    try testing.expect(idx(ranked, "my_doc_notes.txt") < idx(ranked, "undocumented"));
    try testing.expectEqual(@as(?i64, null), sc("doc", "Downloads"));
}

test "very long inputs do not overflow the buffers" {
    var long: [2000]u8 = undefined;
    @memset(&long, 'a');
    try testing.expect(sc("aa", &long) != null);
    try testing.expect(sc(long[0..300], &long) != null);
}
