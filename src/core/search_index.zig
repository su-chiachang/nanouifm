//! Background filename index over a few roots: a port of nanofmCore's SearchIndex.
//!
//! Skips hidden entries, packages' contents (a package itself is indexed, as a non-directory),
//! `node_modules`, `.git` and `Library`, and caps at `max_entries`. Thread-safe: `rebuild` crawls
//! without holding the lock and publishes the finished snapshot atomically, so it may run on a
//! background thread while other threads call `search` / `entryCount`.
//!
//! Paths are plain UTF-8 strings (the Swift original used URLs).
//!
//! No `std.Io`: the crawl reads folders with libc (`opendir`/`readdir`, like `lister.zig`) and the lock
//! is a tiny spin lock around a pointer swap, so a program that keeps `std.Io.Threaded` out of its
//! build (nanoui apps do) can link this.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");

const c = std.c;
const Allocator = std.mem.Allocator;

pub const default_max_depth: usize = 6;
pub const default_max_entries: usize = 200_000;

pub const excluded_names = [_][]const u8{ "node_modules", ".git", "Library" };

/// Directory extensions treated as packages (bundles): indexed, never descended into.
const package_extensions = [_][]const u8{
    ".app",         ".bundle",     ".framework",     ".plugin",      ".kext",       ".xcodeproj",
    ".xcworkspace", ".rtfd",       ".photoslibrary", ".appex",       ".prefPane",   ".saver",
    ".xpc",         ".playground", ".xctest",        ".qlgenerator", ".mdimporter", ".component",
};

/// One search result. `path` is owned by the allocator given to `search`; `name` points into it.
/// Release a result slice with `freeHits`.
pub const SearchHit = struct {
    path: []const u8,
    name: []const u8,
    is_directory: bool,
    score: i64,
};

pub fn freeHits(allocator: Allocator, hits: []SearchHit) void {
    for (hits) |h| allocator.free(h.path);
    allocator.free(hits);
}

const Entry = struct {
    path: []const u8,
    name_start: u32,
    is_directory: bool,

    fn name(e: Entry) []const u8 {
        return e.path[e.name_start..];
    }
};

/// An immutable, reference-counted crawl result. Searches pin one so a concurrent `rebuild`
/// never frees entries from under them.
const Snapshot = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    refs: std.atomic.Value(usize) = .init(1),

    fn release(s: *Snapshot) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) {
            const gpa = s.gpa;
            s.arena.deinit();
            gpa.destroy(s);
        }
    }
};

pub const SearchIndex = struct {
    gpa: Allocator,
    roots: []const []const u8,
    max_depth: usize,
    max_entries: usize,
    mutex: std.atomic.Mutex = .unlocked,
    snapshot: ?*Snapshot = null,

    pub fn init(gpa: Allocator, roots: []const []const u8, max_depth: usize, max_entries: usize) Allocator.Error!SearchIndex {
        const owned = try gpa.alloc([]const u8, roots.len);
        var done: usize = 0;
        errdefer {
            for (owned[0..done]) |r| gpa.free(r);
            gpa.free(owned);
        }
        for (roots, 0..) |r, i| {
            owned[i] = try gpa.dupe(u8, r);
            done += 1;
        }
        return .{ .gpa = gpa, .roots = owned, .max_depth = max_depth, .max_entries = max_entries };
    }

    /// Not safe to call while another thread still uses the index.
    pub fn deinit(self: *SearchIndex) void {
        if (self.snapshot) |s| s.release();
        for (self.roots) |r| self.gpa.free(r);
        self.gpa.free(self.roots);
        self.* = undefined;
    }

    fn lock(self: *SearchIndex) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn unlock(self: *SearchIndex) void {
        self.mutex.unlock();
    }

    /// Crawl the roots and replace the index. Blocking: call it from a background thread.
    pub fn rebuild(self: *SearchIndex) Allocator.Error!void {
        const fresh = try crawl(self.gpa, self.roots, self.max_depth, self.max_entries);
        self.lock();
        const old = self.snapshot;
        self.snapshot = fresh;
        self.unlock();
        if (old) |o| o.release();
    }

    pub fn entryCount(self: *SearchIndex) usize {
        self.lock();
        defer self.unlock();
        return if (self.snapshot) |s| s.entries.len else 0;
    }

    fn acquire(self: *SearchIndex) ?*Snapshot {
        self.lock();
        defer self.unlock();
        const s = self.snapshot orelse return null;
        _ = s.refs.fetchAdd(1, .monotonic);
        return s;
    }

    /// Best matches for `query` (whitespace-trimmed; empty -> none), best first, at most `limit`.
    /// Free the result with `freeHits(allocator, hits)`.
    pub fn search(self: *SearchIndex, allocator: Allocator, query: []const u8, limit: usize) Allocator.Error![]SearchHit {
        const trimmed = std.mem.trim(u8, query, " \t\r\n\x0B\x0C");
        if (trimmed.len == 0 or limit == 0) return allocator.alloc(SearchHit, 0);
        const snap = self.acquire() orelse return allocator.alloc(SearchHit, 0);
        defer snap.release();

        const Scored = struct { score: i64, index: u32 };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(allocator);
        for (snap.entries, 0..) |e, i| {
            if (fuzzy.score(trimmed, e.name())) |sc| try scored.append(allocator, .{ .score = sc, .index = @intCast(i) });
        }
        const entries = snap.entries;
        std.mem.sort(Scored, scored.items, entries, struct {
            fn lessThan(es: []Entry, a: Scored, b: Scored) bool {
                if (a.score != b.score) return a.score > b.score;
                const pa = es[a.index].path;
                const pb = es[b.index].path;
                if (pa.len != pb.len) return pa.len < pb.len;
                return std.mem.lessThan(u8, pa, pb);
            }
        }.lessThan);

        const n = @min(limit, scored.items.len);
        const hits = try allocator.alloc(SearchHit, n);
        var made: usize = 0;
        errdefer {
            for (hits[0..made]) |h| allocator.free(h.path);
            allocator.free(hits);
        }
        for (scored.items[0..n], 0..) |s, k| {
            const e = entries[s.index];
            const path = try allocator.dupe(u8, e.path);
            hits[k] = .{ .path = path, .name = path[e.name_start..], .is_directory = e.is_directory, .score = s.score };
            made += 1;
        }
        return hits;
    }
};

// ---------------------------------------------------------------------------- crawl

const Builder = struct {
    gpa: Allocator,
    arena: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    max_depth: usize,
    max_entries: usize,

    fn full(self: *const Builder) bool {
        return self.entries.items.len >= self.max_entries;
    }

    fn walk(self: *Builder, dir_path: []const u8, depth: usize) Allocator.Error!void {
        if (self.full()) return;
        var zbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dz = toZ(&zbuf, dir_path) orelse return;
        const dir = c.opendir(dz) orelse return;
        var subdirs: std.ArrayList([]const u8) = .empty;
        defer subdirs.deinit(self.gpa);
        {
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |ent| {
                if (self.full()) break;
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
                if (name.len == 0 or name[0] == '.' or isExcluded(name)) continue;

                const path = try join(self.arena, dir_path, name);
                var is_dir = ent.type == c.DT.DIR;
                var is_link = ent.type == c.DT.LNK;
                if (ent.type == c.DT.LNK or ent.type == c.DT.UNKNOWN) {
                    // Resolve through the link for the directory flag; never descend into links.
                    is_dir = isDirectory(path);
                    if (ent.type == c.DT.UNKNOWN) is_link = false;
                }
                const is_pkg = is_dir and isPackageName(name);
                if (is_pkg) is_dir = false;

                const gop = try self.seen.getOrPut(self.gpa, path);
                if (gop.found_existing) continue;
                try self.entries.append(self.gpa, .{
                    .path = path,
                    .name_start = @intCast(path.len - name.len),
                    .is_directory = is_dir,
                });
                // Do not descend into packages or symlinks (avoids cycles).
                if (is_dir and !is_link and depth < self.max_depth) try subdirs.append(self.gpa, path);
            }
        }
        for (subdirs.items) |sub| try self.walk(sub, depth + 1);
    }
};

fn toZ(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// Whether `path` is a folder, following a symlink.
fn isDirectory(path: []const u8) bool {
    var zbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&zbuf, path) orelse return false;
    var st: c.Stat = undefined;
    if (c.stat(pz, &st) != 0) return false;
    return (@as(u32, st.mode) & c.S.IFMT) == c.S.IFDIR;
}

fn crawl(gpa: Allocator, roots: []const []const u8, max_depth: usize, max_entries: usize) Allocator.Error!*Snapshot {
    const snap = try gpa.create(Snapshot);
    errdefer gpa.destroy(snap);
    snap.* = .{ .gpa = gpa, .arena = .init(gpa), .entries = &.{} };
    errdefer snap.arena.deinit();

    var b: Builder = .{
        .gpa = gpa,
        .arena = snap.arena.allocator(),
        .max_depth = max_depth,
        .max_entries = max_entries,
    };
    defer b.entries.deinit(gpa);
    defer b.seen.deinit(gpa);

    for (roots) |root| {
        if (b.full()) break;
        try b.walk(trimTrailingSep(root), 1);
    }
    snap.entries = try b.arena.dupe(Entry, b.entries.items);
    return snap;
}

fn trimTrailingSep(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and std.fs.path.isSep(p[end - 1])) end -= 1;
    return p[0..end];
}

fn join(a: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    const needs_sep = dir.len > 0 and !std.fs.path.isSep(dir[dir.len - 1]);
    const out = try a.alloc(u8, dir.len + @intFromBool(needs_sep) + name.len);
    @memcpy(out[0..dir.len], dir);
    if (needs_sep) out[dir.len] = std.fs.path.sep;
    @memcpy(out[out.len - name.len ..], name);
    return out;
}

fn isExcluded(name: []const u8) bool {
    for (excluded_names) |x| if (std.mem.eql(u8, name, x)) return true;
    return false;
}

fn isPackageName(name: []const u8) bool {
    for (package_extensions) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------- tests

const testing = std.testing;

const Scratch = struct {
    tmp: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn begin() !Scratch {
        var s: Scratch = .{ .tmp = std.testing.tmpDir(.{}) };
        s.len = try s.tmp.dir.realPath(testing.io, &s.buf);
        return s;
    }
    fn deinit(s: *Scratch) void {
        s.tmp.cleanup();
    }
    fn root(s: *const Scratch) []const u8 {
        return s.buf[0..s.len];
    }
    fn file(s: *Scratch, rel: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try s.tmp.dir.createDirPath(testing.io, d);
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = "x" });
    }
    fn dir(s: *Scratch, rel: []const u8) !void {
        try s.tmp.dir.createDirPath(testing.io, rel);
    }
};

fn hasName(hits: []const SearchHit, name: []const u8) bool {
    for (hits) |h| if (std.mem.eql(u8, h.name, name)) return true;
    return false;
}

fn run(idx: *SearchIndex, q: []const u8, limit: usize) ![]SearchHit {
    return idx.search(testing.allocator, q, limit);
}

test "build, search and exclusions" {
    var sc = try Scratch.begin();
    defer sc.deinit();
    try sc.file("Documents/quarterly-report.txt");
    try sc.file("Documents/notes.md");
    try sc.file("Projects/app/main.swift");
    try sc.file("Projects/node_modules/pkg/report-lib.js");
    try sc.file("Projects/.git/report-config");
    try sc.file("Library/Preferences/report.plist");
    try sc.file(".hidden-report/inside.txt");
    try sc.file(".secret-report.txt");
    try sc.file("Fake.app/Contents/report-inner.txt");
    try sc.dir("reports");

    var idx = try SearchIndex.init(testing.allocator, &.{sc.root()}, default_max_depth, default_max_entries);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.entryCount());
    {
        const h = try run(&idx, "report", 50);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 0), h.len);
    }
    try idx.rebuild();
    try testing.expect(idx.entryCount() > 0);

    const hits = try run(&idx, "report", 50);
    defer freeHits(testing.allocator, hits);
    try testing.expect(hasName(hits, "quarterly-report.txt"));
    try testing.expect(hasName(hits, "reports"));
    try testing.expect(!hasName(hits, "report-lib.js")); // node_modules excluded
    try testing.expect(!hasName(hits, "report-config")); // .git excluded
    try testing.expect(!hasName(hits, "report.plist")); // Library excluded
    try testing.expect(!hasName(hits, ".secret-report.txt")); // hidden excluded
    try testing.expect(!hasName(hits, "inside.txt"));
    try testing.expect(!hasName(hits, "report-inner.txt")); // package contents excluded
    {
        const h = try run(&idx, "fake", 50);
        defer freeHits(testing.allocator, h);
        try testing.expect(hasName(h, "Fake.app")); // the package itself is indexed
        try testing.expect(!h[0].is_directory);
    }

    for (hits) |h| {
        if (std.mem.eql(u8, h.name, "reports")) try testing.expect(h.is_directory);
        if (std.mem.eql(u8, h.name, "quarterly-report.txt")) try testing.expect(!h.is_directory);
        try testing.expect(std.mem.startsWith(u8, h.path, sc.root()));
    }
    // Ranking: the folder named "reports" (prefix) beats the longer name; scores descend.
    try testing.expectEqualStrings("reports", hits[0].name);
    for (hits[1..], 0..) |h, i| try testing.expect(hits[i].score >= h.score);

    inline for (.{ "   ", "" }) |q| {
        const h = try run(&idx, q, 50);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 0), h.len);
    }
    {
        const h = try run(&idx, "main", 1);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 1), h.len);
        try testing.expectEqualStrings("main.swift", h[0].name);
    }
    {
        const h = try run(&idx, "zzzzqqq", 50);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 0), h.len);
    }
    {
        const h = try run(&idx, "e", 3);
        defer freeHits(testing.allocator, h);
        try testing.expect(h.len <= 3);
    }
}

test "max depth and max entries" {
    var sc = try Scratch.begin();
    defer sc.deinit();
    try sc.file("a/b/c/deep.txt");
    try sc.file("top.txt");

    {
        var shallow = try SearchIndex.init(testing.allocator, &.{sc.root()}, 2, default_max_entries);
        defer shallow.deinit();
        try shallow.rebuild();
        for ([_]struct { []const u8, []const u8, bool }{
            .{ "deep", "deep.txt", false },
            .{ "b", "b", true },
            .{ "c", "c", false },
        }) |case| {
            const h = try run(&shallow, case[0], 50);
            defer freeHits(testing.allocator, h);
            try testing.expectEqual(case[2], hasName(h, case[1]));
        }
    }
    {
        var full = try SearchIndex.init(testing.allocator, &.{sc.root()}, default_max_depth, default_max_entries);
        defer full.deinit();
        try full.rebuild();
        const h = try run(&full, "deep", 50);
        defer freeHits(testing.allocator, h);
        try testing.expect(hasName(h, "deep.txt"));
    }

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var nb: [32]u8 = undefined;
        try sc.file(try std.fmt.bufPrint(&nb, "bulk/f{d}.txt", .{i}));
    }
    var capped = try SearchIndex.init(testing.allocator, &.{sc.root()}, default_max_depth, 10);
    defer capped.deinit();
    try capped.rebuild();
    try testing.expectEqual(@as(usize, 10), capped.entryCount());
}

test "rebuild picks up changes; multiple and duplicate roots" {
    var s1 = try Scratch.begin();
    defer s1.deinit();
    var s2 = try Scratch.begin();
    defer s2.deinit();
    try s1.file("alpha.txt");
    try s2.file("beta.txt");
    var idx = try SearchIndex.init(testing.allocator, &.{ s1.root(), s2.root(), s1.root() }, default_max_depth, default_max_entries);
    defer idx.deinit();
    try idx.rebuild();
    try testing.expectEqual(@as(usize, 2), idx.entryCount()); // duplicate roots are not double counted

    try s1.file("gamma.txt");
    {
        const h = try run(&idx, "gamma", 50);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 0), h.len);
    }
    try idx.rebuild();
    const h = try run(&idx, "gamma", 50);
    defer freeHits(testing.allocator, h);
    try testing.expectEqual(@as(usize, 1), h.len);
    try testing.expectEqualStrings("gamma.txt", h[0].name);
}

test "missing root and trailing separator" {
    var sc = try Scratch.begin();
    defer sc.deinit();
    try sc.file("one.txt");
    var with_sep_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const with_sep = try std.fmt.bufPrint(&with_sep_buf, "{s}/", .{sc.root()});
    var idx = try SearchIndex.init(testing.allocator, &.{ "/nonexistent-nanofm-test-root", with_sep, sc.root() }, default_max_depth, default_max_entries);
    defer idx.deinit();
    try idx.rebuild();
    try testing.expectEqual(@as(usize, 1), idx.entryCount());
}

test "rebuild on a background thread while searching" {
    var sc = try Scratch.begin();
    defer sc.deinit();
    try sc.file("d/needle-one.txt");
    try sc.file("d/needle-two.txt");
    var idx = try SearchIndex.init(testing.allocator, &.{sc.root()}, default_max_depth, default_max_entries);
    defer idx.deinit();
    try idx.rebuild();

    const Worker = struct {
        fn go(i: *SearchIndex) void {
            var n: usize = 0;
            while (n < 20) : (n += 1) i.rebuild() catch return;
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.go, .{&idx});
    var n: usize = 0;
    while (n < 200) : (n += 1) {
        const h = try run(&idx, "needle", 10);
        defer freeHits(testing.allocator, h);
        try testing.expectEqual(@as(usize, 2), h.len);
        try testing.expectEqual(@as(usize, 3), idx.entryCount());
    }
    t.join();
}
