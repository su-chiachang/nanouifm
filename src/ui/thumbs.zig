//! Thumbnails for the inspector's big preview: a bounded cache over an injectable, asynchronous
//! provider (`Hooks.thumbnail`; the real one is `system_thumbs.zig`, tests install fakes).
//!
//! The view only READS the cache (`lookup`): a file never asked for becomes a pending slot and
//! the provider is called once for it, and the view draws the file's icon until pixels arrive.
//! A provider finishes through its `Done` (on the main thread, from its own callback, or at once
//! inside the call): the pixels are copied into an inbox, the frame is woken, and the inbox is
//! merged into the slots at the start of the next pass (`merge`, called by `Model.applyPending`),
//! when nothing is being drawn: so the bytes a frame handed to nanoui (`ui.image`'s `.pixels`)
//! stay valid for the whole frame, and eviction (least recently used, by count and by bytes)
//! only ever happens there.
//!
//! Slots are keyed by path + modification time + size, so an edited file asks again. The shared
//! state is on the heap and counts its requests in flight: a model that goes away while a
//! provider still holds a `Done` marks it dead, and the last `finish` frees it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Waker = @typeInfo(@FieldType(ui.Context, "waker")).optional.child;

/// Premultiplied BGRA, top row first (what `ui.image` takes as `.pixels`).
pub const Pixels = struct {
    bgra: []const u8,
    width: u32,
    height: u32,
};

/// How a provider says it is done: `finish(null)` when no thumbnail could be made. Called once,
/// on the main thread. The pixels need only live during the call (they are copied).
pub const Done = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, px: ?Pixels) void,

    pub fn finish(self: Done, px: ?Pixels) void {
        self.call(self.ctx, px);
    }
};

/// Starts a thumbnail of `path` whose longer side is about `side` points (the provider picks the
/// scale). Returns at once; `path` is only valid during the call. Never blocks.
pub const Provider = *const fn (path: []const u8, side: u32, done: Done) void;

/// What a lookup found: `key` names the picture for `ui.image` (new content, new key).
pub const Ready = struct {
    key: []const u8,
    px: Pixels,
};

pub const max_slots: usize = 24;
pub const max_bytes: usize = 48 * 1024 * 1024;
/// A single thumbnail larger than this is refused.
pub const max_one: usize = 16 * 1024 * 1024;

const Owned = struct {
    bgra: []u8,
    width: u32,
    height: u32,
};

const State = union(enum) { pending, failed, ready: Owned };

const Slot = struct {
    key: []u8,
    state: State,
    /// The pass that last looked it up.
    used: u64,
};

const Arrival = struct {
    key: []u8,
    px: ?Owned,
};

const Job = struct {
    shared: *Shared,
    key: []u8,
};

pub const Shared = struct {
    gpa: Allocator,
    slots: std.ArrayList(Slot) = .empty,
    inbox: std.ArrayList(Arrival) = .empty,
    in_flight: usize = 0,
    dead: bool = false,
    waker: ?Waker = null,
    /// Counts passes (`merge`).
    pass: u64 = 0,
    bytes: usize = 0,
    /// How many requests were ever made (tests; the cache's hit rate).
    requests: usize = 0,

    pub fn create(gpa: Allocator) Allocator.Error!*Shared {
        const s = try gpa.create(Shared);
        s.* = .{ .gpa = gpa };
        return s;
    }

    pub fn setWaker(self: *Shared, w: ?Waker) void {
        self.waker = w;
    }

    /// The model is going away: frees everything it can. With requests in flight the object
    /// stays (dead) until the last one finishes.
    pub fn close(self: *Shared) void {
        self.dead = true;
        self.waker = null;
        for (self.slots.items) |*s| freeSlot(self.gpa, s);
        self.slots.deinit(self.gpa);
        self.slots = .empty;
        for (self.inbox.items) |*a| freeArrival(self.gpa, a);
        self.inbox.deinit(self.gpa);
        self.inbox = .empty;
        if (self.in_flight == 0) self.gpa.destroy(self);
    }

    fn find(self: *Shared, key: []const u8) ?*Slot {
        for (self.slots.items) |*s| if (std.mem.eql(u8, s.key, key)) return s;
        return null;
    }

    /// The thumbnail of `path` (modified at `mtime`) if it has arrived; otherwise asks `provider`
    /// once and returns null. Reads only: nothing is freed or moved here.
    pub fn lookup(self: *Shared, provider: ?Provider, path: []const u8, mtime: i64, side: u32) ?Ready {
        var kb: [1200]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}\x00{d}\x00{d}", .{ path, mtime, side }) catch return null;
        if (self.find(key)) |s| {
            s.used = self.pass;
            return switch (s.state) {
                .ready => |r| .{ .key = s.key, .px = .{ .bgra = r.bgra, .width = r.width, .height = r.height } },
                else => null,
            };
        }
        const p = provider orelse return null;
        const owned_key = self.gpa.dupe(u8, key) catch return null;
        self.slots.append(self.gpa, .{ .key = owned_key, .state = .pending, .used = self.pass }) catch {
            self.gpa.free(owned_key);
            return null;
        };
        const job = self.gpa.create(Job) catch return null; // stays pending: never asked again
        const job_key = self.gpa.dupe(u8, key) catch {
            self.gpa.destroy(job);
            return null;
        };
        job.* = .{ .shared = self, .key = job_key };
        self.in_flight += 1;
        self.requests += 1;
        p(path, side, .{ .ctx = job, .call = finish });
        return null;
    }

    /// The provider's answer (via `Done`): copied into the inbox, and a frame is woken.
    fn finish(ctx: *anyopaque, px: ?Pixels) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        const s = job.shared;
        const gpa = s.gpa;
        s.in_flight -= 1;
        defer {
            if (s.dead and s.in_flight == 0) gpa.destroy(s);
            gpa.destroy(job);
        }
        if (s.dead) {
            gpa.free(job.key);
            return;
        }
        var owned: ?Owned = null;
        if (px) |p| {
            const n = @as(usize, p.width) * p.height * 4;
            if (n > 0 and n <= max_one and p.bgra.len >= n) {
                if (gpa.dupe(u8, p.bgra[0..n])) |copy| owned = .{ .bgra = copy, .width = p.width, .height = p.height } else |_| {}
            }
        }
        s.inbox.append(gpa, .{ .key = job.key, .px = owned }) catch {
            gpa.free(job.key);
            if (owned) |o| gpa.free(o.bgra);
            return;
        };
        if (s.waker) |w| w.wake(w.ctx);
    }

    /// Start of a pass: arrivals into their slots, then eviction down to the bounds. True if
    /// anything arrived.
    pub fn merge(self: *Shared) bool {
        self.pass += 1;
        var any = false;
        for (self.inbox.items) |*a| {
            any = true;
            if (self.find(a.key)) |s| {
                if (a.px) |o| {
                    s.state = .{ .ready = o };
                    self.bytes += o.bgra.len;
                    a.px = null; // the slot owns it now
                } else s.state = .failed;
            }
            freeArrival(self.gpa, a);
        }
        self.inbox.clearRetainingCapacity();
        self.evict();
        return any;
    }

    fn evict(self: *Shared) void {
        while (self.slots.items.len > max_slots or self.bytes > max_bytes) {
            // The least recently used slot that is not still waiting for its answer.
            var victim: ?usize = null;
            for (self.slots.items, 0..) |s, i| {
                if (s.state == .pending) continue;
                if (victim == null or s.used < self.slots.items[victim.?].used) victim = i;
            }
            const i = victim orelse return;
            var s = self.slots.orderedRemove(i);
            if (s.state == .ready) self.bytes -= s.state.ready.bgra.len;
            freeSlot(self.gpa, &s);
        }
    }
};

fn freeSlot(gpa: Allocator, s: *Slot) void {
    gpa.free(s.key);
    if (s.state == .ready) gpa.free(s.state.ready.bgra);
}

fn freeArrival(gpa: Allocator, a: *Arrival) void {
    gpa.free(a.key);
    if (a.px) |o| gpa.free(o.bgra);
}

// ---- tests ----

const testing = std.testing;

var held: ?Done = null;
var asked: usize = 0;

fn holdProvider(path: []const u8, side: u32, done: Done) void {
    _ = path;
    _ = side;
    asked += 1;
    held = done;
}

fn instantProvider(path: []const u8, side: u32, done: Done) void {
    _ = path;
    _ = side;
    asked += 1;
    const px: [16]u8 = @splat(255);
    done.finish(.{ .bgra = &px, .width = 2, .height = 2 });
}

test "a lookup asks the provider once; the answer shows after the next merge" {
    asked = 0;
    held = null;
    const s = try Shared.create(testing.allocator);
    defer s.close();
    try testing.expect(s.lookup(holdProvider, "/a.png", 5, 200) == null);
    try testing.expect(s.lookup(holdProvider, "/a.png", 5, 200) == null);
    try testing.expectEqual(@as(usize, 1), asked); // one request while pending
    const px: [16]u8 = @splat(7);
    held.?.finish(.{ .bgra = &px, .width = 2, .height = 2 });
    try testing.expect(s.lookup(holdProvider, "/a.png", 5, 200) == null); // not before the merge
    try testing.expect(s.merge());
    const r = s.lookup(holdProvider, "/a.png", 5, 200).?;
    try testing.expectEqual(@as(u32, 2), r.px.width);
    try testing.expectEqual(@as(u8, 7), r.px.bgra[3]);
    try testing.expectEqual(@as(usize, 1), asked);
    // An edited file (new mtime) is a new picture.
    try testing.expect(s.lookup(holdProvider, "/a.png", 6, 200) == null);
    try testing.expectEqual(@as(usize, 2), asked);
    held.?.finish(null); // a failure is remembered too
    _ = s.merge();
    try testing.expect(s.lookup(holdProvider, "/a.png", 6, 200) == null);
    try testing.expectEqual(@as(usize, 2), asked);
}

test "the cache is bounded; the least recently used go first" {
    asked = 0;
    const s = try Shared.create(testing.allocator);
    defer s.close();
    var name: [32]u8 = undefined;
    for (0..max_slots + 6) |i| {
        const p = try std.fmt.bufPrint(&name, "/f{d}.png", .{i});
        _ = s.lookup(instantProvider, p, 1, 100);
        _ = s.merge();
    }
    try testing.expect(s.slots.items.len <= max_slots);
    // The newest is kept, the oldest is gone (a new lookup asks again).
    const before = asked;
    try testing.expect(s.lookup(instantProvider, "/f29.png", 1, 100) != null);
    try testing.expectEqual(before, asked);
    try testing.expect(s.lookup(instantProvider, "/f0.png", 1, 100) == null);
    try testing.expectEqual(before + 1, asked);
}

test "a model that goes away with a request in flight leaves nothing behind" {
    held = null;
    const s = try Shared.create(testing.allocator);
    try testing.expect(s.lookup(holdProvider, "/late.png", 1, 100) == null);
    s.close(); // the provider still holds its Done
    const px: [16]u8 = @splat(1);
    held.?.finish(.{ .bgra = &px, .width = 2, .height = 2 }); // frees the shared state (the leak checker proves it)
}
