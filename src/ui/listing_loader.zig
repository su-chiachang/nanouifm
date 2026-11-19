//! The loader: what the model asks for folders when listing is asynchronous (`Config.listing`).
//! A request names a tab, what to do once its folders are read (`Intent`: visit, back, forward,
//! reload, open a folder in place, the column view's follow-ups) and the folders to read. The
//! tab keeps showing what it showed, history included, until the answer lands; `listing_apply`
//! then runs the very same synchronous code as without a loader, with the folders already read.
//!
//! Generations: every request gets a sequence number, and a result only lands while its
//! request is still in `pending`. A newer request of the same kind for the tab (navigating
//! again, reloading again) removes the older one, so the older result arrives later and is
//! dropped and freed; navigating also removes the tab's other pending work (a reload or a column
//! follow-up for the folder it just left).
//!
//! Bounded work: at most `max_running` jobs are in flight; a request that finds them all busy
//! waits in `pending` (not started), where a newer request of its kind replaces it. One tab
//! can therefore never have more than one waiting request per kind, however fast it navigates.
//!
//! Everything here runs on the main thread; only `listing_runner.Job.read` runs elsewhere.
const std = @import("std");
const Allocator = std.mem.Allocator;
const runner_mod = @import("listing_runner.zig");

pub const Runner = runner_mod.Runner;
pub const Shared = runner_mod.Shared;
pub const Job = runner_mod.Job;
pub const Waker = runner_mod.Waker;

/// What kinds of requests supersede each other.
pub const Class = enum { nav, reload, column, expand };

/// What happens when the folders are in. Strings are owned by the pending request.
pub const Intent = union(enum) {
    /// `Model.navigate`: go to this folder, with a history entry.
    visit: []const u8,
    back,
    forward,
    /// Read the tab's folder (and its open folders and columns) again, keeping selection and scroll.
    reload,
    /// A disclosure triangle opened this folder in the list.
    expand: []const u8,
    /// The column view selected something in column `depth`: its follow-up (the next column, the
    /// tab's folder) needs folders.
    col_after: usize,
    /// The column view's tab folder follows a column (the Left key).
    col_loc: []const u8,
    /// The column stack is built again for the tab's folder.
    col_rebuild,

    pub fn class(self: Intent) Class {
        return switch (self) {
            .visit, .back, .forward => .nav,
            .reload => .reload,
            .expand => .expand,
            .col_after, .col_loc, .col_rebuild => .column,
        };
    }

    fn dupe(self: Intent, gpa: Allocator) Allocator.Error!Intent {
        return switch (self) {
            .visit => |p| .{ .visit = try gpa.dupe(u8, p) },
            .expand => |p| .{ .expand = try gpa.dupe(u8, p) },
            .col_loc => |p| .{ .col_loc = try gpa.dupe(u8, p) },
            else => self,
        };
    }

    fn free(self: Intent, gpa: Allocator) void {
        switch (self) {
            .visit, .expand, .col_loc => |p| gpa.free(p),
            else => {},
        }
    }
};

pub const Pending = struct {
    /// The request's generation.
    seq: u32,
    tab: u32,
    intent: Intent,
    /// The folder the tab showed when it asked (a landing checks it still does).
    base: []u8,
    /// The folders to read (owned).
    paths: [][]u8,
    /// Handed to the runner (otherwise it waits for a free slot).
    started: bool = false,
    /// Paths to select once a reload lands (the palette revealing a file in a tab it just made).
    select: ?[][]u8 = null,

    pub fn deinit(self: *Pending, gpa: Allocator) void {
        self.intent.free(gpa);
        gpa.free(self.base);
        for (self.paths) |p| gpa.free(p);
        gpa.free(self.paths);
        if (self.select) |s| freeStrings(gpa, s);
        self.* = undefined;
    }
};

fn dupeStrings(gpa: Allocator, src: []const []const u8) Allocator.Error![][]u8 {
    const list = try gpa.alloc([]u8, src.len);
    var made: usize = 0;
    errdefer {
        for (list[0..made]) |p| gpa.free(p);
        gpa.free(list);
    }
    for (src, list) |s, *dst| {
        dst.* = try gpa.dupe(u8, s);
        made += 1;
    }
    return list;
}

fn freeStrings(gpa: Allocator, list: [][]u8) void {
    for (list) |p| gpa.free(p);
    gpa.free(list);
}

pub const Loader = struct {
    gpa: Allocator,
    runner: ?Runner,
    max_running: usize,
    shared: *Shared,
    pending: std.ArrayList(Pending) = .empty,
    next_seq: u32 = 1,
    /// `listing_apply.drain` is running (a landing does not start another drain).
    draining: bool = false,
    /// Counters (tests): requests made, jobs started, results dropped as stale, reads that missed
    /// the preloaded folders and went to the disk on the main thread.
    requests: u32 = 0,
    started: u32 = 0,
    dropped: u32 = 0,
    fallbacks: u32 = 0,

    /// `cfg` null: no runner, `isAsync` is false and the model reads inline.
    pub fn create(gpa: Allocator, cfg: ?runner_mod.Config) Allocator.Error!*Loader {
        const l = try gpa.create(Loader);
        errdefer gpa.destroy(l);
        l.* = .{ .gpa = gpa, .runner = if (cfg) |c| c.runner else null, .max_running = if (cfg) |c| @max(1, c.max_running) else 1, .shared = try Shared.create(gpa) };
        return l;
    }

    pub fn destroy(self: *Loader) void {
        for (self.pending.items) |*p| p.deinit(self.gpa);
        self.pending.deinit(self.gpa);
        self.shared.close();
        self.gpa.destroy(self);
    }

    pub fn setWaker(self: *Loader, w: ?Waker) void {
        self.shared.setWaker(w);
    }

    pub fn isAsync(self: *const Loader) bool {
        return self.runner != null;
    }

    /// `self` when listing is asynchronous, else null (what `Tab.Opts.loader` holds).
    pub fn ifAsync(self: *Loader) ?*Loader {
        return if (self.runner != null) self else null;
    }

    /// Asks for `paths` to be read, then `intent` to run with them (`listing_apply`). `base` is
    /// the folder the tab shows now. Everything is copied.
    pub fn request(self: *Loader, tab_id: u32, base: []const u8, intent: Intent, paths: []const []const u8) Allocator.Error!void {
        const gpa = self.gpa;
        var rec = try self.build(tab_id, base, intent, paths);
        self.pending.ensureUnusedCapacity(gpa, 1) catch |e| {
            rec.deinit(gpa);
            return e;
        };
        self.supersede(&rec);
        self.next_seq +%= 1;
        self.requests += 1;
        self.pending.appendAssumeCapacity(rec);
        try self.pump();
    }

    fn build(self: *Loader, tab_id: u32, base: []const u8, intent: Intent, paths: []const []const u8) Allocator.Error!Pending {
        const gpa = self.gpa;
        const it = try intent.dupe(gpa);
        errdefer it.free(gpa);
        const b = try gpa.dupe(u8, base);
        errdefer gpa.free(b);
        const list = try dupeStrings(gpa, paths);
        return .{ .seq = self.next_seq, .tab = tab_id, .intent = it, .base = b, .paths = list };
    }

    /// Removes the pending requests `new` replaces (see the file's comment). A reload's
    /// `select` passes on to its replacement.
    fn supersede(self: *Loader, new: *Pending) void {
        const class = new.intent.class();
        var i = self.pending.items.len;
        while (i > 0) {
            i -= 1;
            const p = &self.pending.items[i];
            if (p.tab != new.tab) continue;
            const same = switch (class) {
                .nav => true, // going elsewhere ends everything asked of the folder left behind
                .reload, .column => p.intent.class() == class,
                .expand => p.intent.class() == .expand and std.mem.eql(u8, p.intent.expand, new.intent.expand),
            };
            if (!same) continue;
            if (class == .reload and new.select == null) {
                new.select = p.select;
                p.select = null;
            }
            var gone = self.pending.orderedRemove(i);
            gone.deinit(self.gpa);
        }
    }

    /// Forgets the tab's pending requests of `class` (a synchronous reload makes them stale).
    pub fn cancel(self: *Loader, tab_id: u32, class: Class) void {
        var i = self.pending.items.len;
        while (i > 0) {
            i -= 1;
            if (self.pending.items[i].tab != tab_id or self.pending.items[i].intent.class() != class) continue;
            var gone = self.pending.orderedRemove(i);
            gone.deinit(self.gpa);
        }
    }

    /// A request of `class` for the tab is waiting or running.
    pub fn has(self: *const Loader, tab_id: u32, class: Class) bool {
        for (self.pending.items) |p| if (p.tab == tab_id and p.intent.class() == class) return true;
        return false;
    }

    /// The tab is waiting for a folder it asked for: a navigation, a folder opened in place, a
    /// column's follow-up, or its first listing (`listed` false). A refresh of what it already
    /// shows (a reload) does not count.
    pub fn loading(self: *const Loader, tab_id: u32, listed: bool) bool {
        for (self.pending.items) |p| {
            if (p.tab != tab_id) continue;
            if (p.intent.class() != .reload or !listed) return true;
        }
        return false;
    }

    /// Selects `paths` when the tab's pending reload lands; false when it has none (select now).
    pub fn selectAfter(self: *Loader, tab_id: u32, paths: []const []const u8) Allocator.Error!bool {
        for (self.pending.items) |*p| {
            if (p.tab != tab_id or p.intent.class() != .reload) continue;
            const list = try dupeStrings(self.gpa, paths);
            if (p.select) |old| freeStrings(self.gpa, old);
            p.select = list;
            return true;
        }
        return false;
    }

    /// The index in `pending` of request `seq`, if it is still wanted.
    pub fn indexOf(self: *const Loader, seq: u32) ?usize {
        for (self.pending.items, 0..) |p, i| if (p.seq == seq) return i;
        return null;
    }

    /// Hands waiting requests to the runner while there is room.
    pub fn pump(self: *Loader) Allocator.Error!void {
        const run = self.runner orelse return;
        for (self.pending.items) |*p| {
            if (p.started) continue;
            if (self.shared.in_flight >= self.max_running) return;
            const s = self.shared;
            try s.arrivals.ensureTotalCapacity(self.gpa, s.arrivals.items.len + s.in_flight + 1);
            const job = try self.gpa.create(Job);
            errdefer self.gpa.destroy(job);
            const paths = try dupeStrings(self.gpa, p.paths);
            errdefer freeStrings(self.gpa, paths);
            job.* = .{ .gpa = self.gpa, .shared = s, .seq = p.seq, .paths = paths };
            p.started = true;
            self.started += 1;
            s.in_flight += 1;
            run(job); // may finish inline (`runNow`): `deliver` then appends to `arrivals`
        }
    }
};

// ---- tests ----

const testing = std.testing;

var held: std.ArrayList(*Job) = .empty;

fn holdRunner(job: *Job) void {
    held.append(testing.allocator, job) catch unreachable;
}

fn releaseAll() void {
    while (held.items.len > 0) held.orderedRemove(0).run();
}

test "a newer request replaces the waiting one, and work in flight is bounded" {
    held = .empty;
    defer held.deinit(testing.allocator);
    defer releaseAll(); // runs after `destroy`: the model is gone, so the jobs read nothing and free themselves
    const l = try Loader.create(testing.allocator, .{ .runner = holdRunner, .max_running = 2 });
    defer l.destroy();
    var buf: [16]u8 = undefined;
    for (0..20) |i| {
        const p = try std.fmt.bufPrint(&buf, "/nope/{d}", .{i});
        try l.request(7, "/", .{ .visit = p }, &.{p});
    }
    try testing.expectEqual(@as(usize, 2), held.items.len); // two jobs in flight, no more threads
    try testing.expectEqual(@as(usize, 1), l.pending.items.len); // one request per kind and tab
    try testing.expectEqual(@as(u32, 20), l.requests);
    try testing.expect(l.pending.items[0].seq == 20 and !l.pending.items[0].started);
}

test "a request of another tab, or another kind, does not replace it" {
    held = .empty;
    defer held.deinit(testing.allocator);
    defer releaseAll(); // after `destroy` (see above): no folder is ever read here
    const l = try Loader.create(testing.allocator, .{ .runner = holdRunner, .max_running = 8 });
    defer l.destroy();
    try l.request(1, "/", .{ .visit = "/a" }, &.{"/a"});
    try l.request(2, "/", .{ .visit = "/b" }, &.{"/b"});
    try l.request(1, "/", .reload, &.{"/"});
    try testing.expectEqual(@as(usize, 3), l.pending.items.len);
    try l.request(1, "/", .{ .visit = "/c" }, &.{"/c"}); // navigating ends the reload of the folder left
    try testing.expectEqual(@as(usize, 2), l.pending.items.len);
    try testing.expect(l.has(1, .nav) and !l.has(1, .reload) and l.has(2, .nav));
}
