//! The file index behind the command palette's "Files & Folders": the core's `SearchIndex` over
//! the roots (the config's own, plus the sidebar's Favorites and Pinned), crawled off the UI
//! thread. Nothing here touches the disk unless `Config.index` asks for an index, so a test
//! (default: none) never reads a folder it didn't make.
//!
//! A crawl is a `Job` handed to the config's `Runner`; the default runner starts a detached thread
//! (main.zig), a test passes one that runs the job at once or keeps it to run later. The index
//! lives in a reference-counted `Shared` so a crawl still running when the roots change, or the
//! model goes away, owns what it uses. When a crawl ends it bumps `generation` and wakes a frame;
//! the palette notices and searches again.
//!
//! The index is rebuilt when the roots change (the sidebar's `revision` moves: a favorite or a pin
//! was added), and when the palette opens and the last crawl is older than `stale_after` seconds
//! of the frame clock.
const std = @import("std");
const Allocator = std.mem.Allocator;
const search_index = @import("../core/search_index.zig");
const watch = @import("watch.zig");

const SearchIndex = search_index.SearchIndex;
pub const SearchHit = search_index.SearchHit;

/// An index older than this (seconds of the frame clock) is crawled again when the palette opens.
pub const stale_after: f64 = 600;

/// How many hits one search asks for.
pub const hit_limit: usize = 60;

pub const Config = struct {
    /// Folders indexed besides the sidebar's Favorites and Pinned (main.zig: Home's Desktop,
    /// Documents and Downloads). Copied.
    roots: []const []const u8 = &.{},
    /// Runs a crawl; null starts a detached thread for it.
    runner: ?Runner = null,
    max_depth: usize = search_index.default_max_depth,
    max_entries: usize = search_index.default_max_entries,
};

/// What runs a `Job`: it calls `job.run()` now, or on a thread, or later (tests).
pub const Runner = *const fn (job: *Job) void;

/// What a crawl and the model share; freed when the last holder lets go.
const Shared = struct {
    gpa: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    index: SearchIndex,
    building: std.atomic.Value(bool) = .init(false),
    /// Crawls finished so far.
    generation: std.atomic.Value(u32) = .init(0),
    waker: ?watch.Waker = null,

    fn release(s: *Shared) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = s.gpa;
        s.index.deinit();
        gpa.destroy(s);
    }
};

/// One crawl, owned by whoever runs it (`run` frees it).
pub const Job = struct {
    gpa: Allocator,
    shared: *Shared,

    /// Crawls the roots (blocking: the runner decides on which thread), publishes the result,
    /// asks for a frame and frees the job.
    pub fn run(job: *Job) void {
        const s = job.shared;
        s.index.rebuild() catch {};
        _ = s.generation.fetchAdd(1, .release);
        s.building.store(false, .release);
        if (s.waker) |w| w.wake(w.ctx);
        const gpa = job.gpa;
        s.release();
        gpa.destroy(job);
    }

    fn thread(job: *Job) void {
        job.run();
    }
};

pub const Index = struct {
    gpa: Allocator = undefined,
    enabled: bool = false,
    cfg_roots: [][]u8 = &.{},
    runner: ?Runner = null,
    max_depth: usize = 0,
    max_entries: usize = 0,
    shared: ?*Shared = null,
    /// The sidebar revision the roots were last computed for (null: never).
    revision: ?u32 = null,
    /// The frame clock when the last crawl was started.
    started_at: f64 = 0,
    waker: ?watch.Waker = null,
    /// Crawls started (tests count them).
    crawls: u32 = 0,

    /// Turns the index on (null `cfg`: it stays off and `sync`, `search` do nothing).
    pub fn configure(self: *Index, gpa: Allocator, cfg: ?Config) Allocator.Error!void {
        const c = cfg orelse return;
        const roots = try gpa.alloc([]u8, c.roots.len);
        var made: usize = 0;
        errdefer {
            for (roots[0..made]) |r| gpa.free(r);
            gpa.free(roots);
        }
        for (c.roots, roots) |src, *dst| {
            dst.* = try gpa.dupe(u8, src);
            made += 1;
        }
        self.* = .{ .gpa = gpa, .enabled = true, .cfg_roots = roots, .runner = c.runner, .max_depth = c.max_depth, .max_entries = c.max_entries };
    }

    pub fn deinit(self: *Index) void {
        if (!self.enabled) return;
        if (self.shared) |s| {
            s.waker = null; // a crawl still running at quit must not wake a window that is gone
            s.release();
        }
        for (self.cfg_roots) |r| self.gpa.free(r);
        self.gpa.free(self.cfg_roots);
        self.* = .{};
    }

    /// Lets a finished crawl ask for a frame (the context's waker, handed over each pass).
    pub fn setWaker(self: *Index, w: ?watch.Waker) void {
        self.waker = w;
        if (self.shared) |s| s.waker = w;
    }

    /// Crawls again when the sidebar's folders changed (`revision`), or, with `if_stale`, when
    /// the last crawl is older than `stale_after` at frame clock `now`. A crawl still running
    /// for these roots is left to finish.
    pub fn refresh(self: *Index, folders: []const []const u8, revision: u32, now: f64, if_stale: bool) Allocator.Error!void {
        if (!self.enabled) return;
        const roots_changed = self.revision == null or self.revision.? != revision;
        const stale = if_stale and (self.shared == null or now - self.started_at > stale_after);
        if (!roots_changed and !stale) return;
        if (roots_changed) try self.replaceShared(folders);
        const s = self.shared.?;
        if (s.building.load(.acquire)) return;
        self.revision = revision;
        self.started_at = now;
        try self.start(s);
    }

    /// A fresh `Shared` for the config's roots plus `folders`; the old one goes when its crawl does.
    fn replaceShared(self: *Index, folders: []const []const u8) Allocator.Error!void {
        var roots: std.ArrayList([]const u8) = .empty;
        defer roots.deinit(self.gpa);
        for (self.cfg_roots) |r| try roots.append(self.gpa, r);
        outer: for (folders) |f| {
            for (roots.items) |r| if (std.mem.eql(u8, r, f)) continue :outer;
            try roots.append(self.gpa, f);
        }
        const s = try self.gpa.create(Shared);
        errdefer self.gpa.destroy(s);
        s.* = .{ .gpa = self.gpa, .index = try SearchIndex.init(self.gpa, roots.items, self.max_depth, self.max_entries), .waker = self.waker };
        if (self.shared) |old| old.release();
        self.shared = s;
    }

    fn start(self: *Index, s: *Shared) Allocator.Error!void {
        const job = try self.gpa.create(Job);
        job.* = .{ .gpa = self.gpa, .shared = s };
        _ = s.refs.fetchAdd(1, .monotonic);
        s.building.store(true, .release);
        self.crawls += 1;
        if (self.runner) |run| return run(job);
        const t = std.Thread.spawn(.{}, Job.thread, .{job}) catch {
            s.building.store(false, .release);
            s.release();
            self.gpa.destroy(job);
            return;
        };
        t.detach();
    }

    /// Best matches for `query` among the indexed files and folders, best first. Free with
    /// `search_index.freeHits`.
    pub fn search(self: *Index, gpa: Allocator, query: []const u8) Allocator.Error![]SearchHit {
        const s = self.shared orelse return gpa.alloc(SearchHit, 0);
        return s.index.search(gpa, query, hit_limit);
    }

    /// How many crawls have finished (the palette searches again when this moves).
    pub fn generation(self: *const Index) u32 {
        return if (self.shared) |s| s.generation.load(.acquire) else 0;
    }

    pub fn isBuilding(self: *const Index) bool {
        return if (self.shared) |s| s.building.load(.acquire) else false;
    }

    pub fn entryCount(self: *Index) usize {
        return if (self.shared) |s| s.index.entryCount() else 0;
    }
};

/// A runner that crawls at once, on the calling thread.
pub fn runNow(job: *Job) void {
    job.run();
}
