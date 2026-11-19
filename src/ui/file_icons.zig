//! Per-file-type icons for the rows, the path bar and the inspector's fallback: a bounded cache over
//! an injectable, asynchronous provider (`Hooks.file_icon`; the real one is `system_file_icon.zig`,
//! tests install fakes). It follows `thumbs.zig`'s discipline, with one difference: icons are asked
//! for by KEY, not by path, so a folder of ten thousand `.txt` files costs ONE request.
//!
//! A key is the file's lowercased extension, a fixed key for plain folders and for extensionless
//! files, or (only for things whose icon is its own: an application, the volume's root, the home
//! folder) the path. A key and a pixel side make one slot.
//!
//! The view only READS the cache (`lookup`): a key never asked for becomes a pending slot and the
//! provider is called once for it; the view draws the generic symbol until pixels arrive. A provider
//! finishes through its `Done` (on the main thread, from its own callback, or at once inside the
//! call): the pixels are copied into an inbox, the frame is woken, and the inbox is merged into the
//! slots at the start of the next pass (`merge`, from `Model.applyPending`), when nothing is being
//! drawn. So the bytes a frame handed to nanoui stay valid for the whole frame, and eviction (least
//! recently used, by count and by bytes) only ever happens there. A failed key stays a failed slot
//! (never asked again) until eviction removes it.
//!
//! At most `max_in_flight` requests are out at once. A lookup past that cap returns null WITHOUT
//! making a slot, so the key is simply asked again by a later frame; every finished request wakes
//! one. The shared state is on the heap and counts its requests in flight: a model that goes away
//! while a provider still holds a `Done` marks it dead, and the last `finish` frees it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const thumbs = @import("thumbs.zig");

pub const Pixels = thumbs.Pixels;
pub const Done = thumbs.Done;
pub const Waker = thumbs.Waker;

/// What an icon is asked for by.
pub const Key = union(enum) {
    /// Any plain folder.
    folder,
    /// A file with no (usable) extension.
    file,
    /// A file type: the extension, lowercase, without the dot.
    ext: []const u8,
    /// An item whose icon is its own: the absolute path.
    path: []const u8,
};

/// Starts an icon for `key` of about `side` x `side` pixels. Returns at once and never blocks (it is
/// called from the view pass); `key`'s strings are only valid during the call. The answer goes
/// through `done` (on the main thread; null when no icon could be made).
pub const Provider = *const fn (key: Key, side: u32, done: Done) void;

/// What a lookup found: `key` names the picture for `ui.image` (new content, new key).
pub const Ready = struct {
    key: []const u8,
    px: Pixels,
};

/// Pixels of a row's icon (16 points at twice the density), and of the inspector's (64 points).
pub const row_side: u32 = 32;
pub const large_side: u32 = 128;

pub const max_slots: usize = 512;
pub const max_bytes: usize = 8 * 1024 * 1024;
/// A single icon larger than this is refused.
pub const max_one: usize = 1024 * 1024;
pub const max_in_flight: usize = 8;
/// Longer extensions are not file types.
pub const max_ext: usize = 32;
/// Longer paths are not asked for (the symbol stays).
const max_key: usize = 1100;

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
    slot: *Slot,
    px: ?Owned,
};

const Job = struct {
    shared: *Shared,
    slot: *Slot,
};

pub const Shared = struct {
    gpa: Allocator,
    /// By the slot's own key. Values are heap slots, so a rehash never moves one.
    slots: std.StringHashMapUnmanaged(*Slot) = .empty,
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
        var it = self.slots.valueIterator();
        while (it.next()) |sp| freeSlot(self.gpa, sp.*);
        self.slots.deinit(self.gpa);
        self.slots = .empty;
        // An arrival's pixels are its own until merged; its slot was just freed above.
        for (self.inbox.items) |a| if (a.px) |o| self.gpa.free(o.bgra);
        self.inbox.deinit(self.gpa);
        self.inbox = .empty;
        if (self.in_flight == 0) self.gpa.destroy(self);
    }

    /// How many slots there are (tests).
    pub fn count(self: *const Shared) usize {
        return self.slots.count();
    }

    /// The icon for `key` at `side` if it has arrived; otherwise asks `provider` once and returns
    /// null. Reads only: nothing is freed or moved here. No provider: null, at once.
    pub fn lookup(self: *Shared, provider: ?Provider, key: Key, side: u32) ?Ready {
        const p = provider orelse return null;
        var kb: [max_key + 16]u8 = undefined;
        const name = cacheKey(&kb, key, side) orelse return null;
        if (self.slots.get(name)) |s| {
            s.used = self.pass;
            return switch (s.state) {
                .ready => |r| .{ .key = s.key, .px = .{ .bgra = r.bgra, .width = r.width, .height = r.height } },
                else => null,
            };
        }
        // Too many out already: no slot, the key is asked again by a later frame.
        if (self.in_flight >= max_in_flight) return null;
        const slot = self.gpa.create(Slot) catch return null;
        const owned_key = self.gpa.dupe(u8, name) catch {
            self.gpa.destroy(slot);
            return null;
        };
        slot.* = .{ .key = owned_key, .state = .pending, .used = self.pass };
        const job = self.gpa.create(Job) catch {
            freeSlot(self.gpa, slot);
            return null;
        };
        self.slots.put(self.gpa, slot.key, slot) catch {
            self.gpa.destroy(job);
            freeSlot(self.gpa, slot);
            return null;
        };
        job.* = .{ .shared = self, .slot = slot };
        self.in_flight += 1;
        self.requests += 1;
        p(key, side, .{ .ctx = job, .call = finish });
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
        if (s.dead) return;
        var owned: ?Owned = null;
        if (px) |p| {
            const n = @as(usize, p.width) * p.height * 4;
            if (n > 0 and n <= max_one and p.bgra.len >= n) {
                if (gpa.dupe(u8, p.bgra[0..n])) |copy| owned = .{ .bgra = copy, .width = p.width, .height = p.height } else |_| {}
            }
        }
        // A slot stays pending (so it is never evicted) until `merge` has read this arrival.
        s.inbox.append(gpa, .{ .slot = job.slot, .px = owned }) catch {
            if (owned) |o| gpa.free(o.bgra);
            job.slot.state = .failed;
            return;
        };
        if (s.waker) |w| w.wake(w.ctx);
    }

    /// Start of a pass: arrivals into their slots, then eviction down to the bounds. True if
    /// anything arrived.
    pub fn merge(self: *Shared) bool {
        self.pass += 1;
        var any = false;
        for (self.inbox.items) |a| {
            any = true;
            if (a.px) |o| {
                a.slot.state = .{ .ready = o };
                self.bytes += o.bgra.len;
            } else a.slot.state = .failed;
        }
        self.inbox.clearRetainingCapacity();
        self.evict();
        return any;
    }

    fn evict(self: *Shared) void {
        while (self.slots.count() > max_slots or self.bytes > max_bytes) {
            // The least recently used slot that is not still waiting for its answer.
            var victim: ?*Slot = null;
            var it = self.slots.valueIterator();
            while (it.next()) |sp| {
                const s = sp.*;
                if (s.state == .pending) continue;
                if (victim == null or s.used < victim.?.used) victim = s;
            }
            const v = victim orelse return;
            if (v.state == .ready) self.bytes -= v.state.ready.bgra.len;
            _ = self.slots.remove(v.key);
            freeSlot(self.gpa, v);
        }
    }
};

/// The slot's name: kind, size, then the extension or path ("e32\x00pdf").
fn cacheKey(buf: []u8, key: Key, side: u32) ?[]const u8 {
    return switch (key) {
        .folder => std.fmt.bufPrint(buf, "d{d}", .{side}) catch null,
        .file => std.fmt.bufPrint(buf, "f{d}", .{side}) catch null,
        .ext => |e| if (e.len == 0 or e.len > max_ext) null else std.fmt.bufPrint(buf, "e{d}\x00{s}", .{ side, e }) catch null,
        .path => |p| if (p.len == 0 or p.len > max_key) null else std.fmt.bufPrint(buf, "p{d}\x00{s}", .{ side, p }) catch null,
    };
}

fn freeSlot(gpa: Allocator, s: *Slot) void {
    gpa.free(s.key);
    if (s.state == .ready) gpa.free(s.state.ready.bgra);
    gpa.destroy(s);
}

// ---- tests ----

const testing = std.testing;

var held: [64]?Done = @splat(null);
var held_n: usize = 0;
var asked: usize = 0;

fn reset() void {
    held = @splat(null);
    held_n = 0;
    asked = 0;
}

fn holdProvider(key: Key, side: u32, done: Done) void {
    _ = key;
    _ = side;
    asked += 1;
    if (held_n < held.len) {
        held[held_n] = done;
        held_n += 1;
    }
}

fn instantProvider(key: Key, side: u32, done: Done) void {
    _ = key;
    _ = side;
    asked += 1;
    const px: [16]u8 = @splat(255);
    done.finish(.{ .bgra = &px, .width = 2, .height = 2 });
}

fn failProvider(key: Key, side: u32, done: Done) void {
    _ = key;
    _ = side;
    asked += 1;
    done.finish(null);
}

/// Answers (with a failure) every request still held: a request nobody answers owns a job.
fn releaseRest() void {
    for (&held) |*h| if (h.*) |d| {
        d.finish(null);
        h.* = null;
    };
}

fn release(i: usize, v: u8) void {
    const px: [16]u8 = @splat(v);
    held[i].?.finish(.{ .bgra = &px, .width = 2, .height = 2 });
    held[i] = null;
}

test "ten thousand lookups of one extension make one request; the answer shows after the next merge" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    for (0..10_000) |_| try testing.expect(s.lookup(holdProvider, .{ .ext = "txt" }, row_side) == null);
    try testing.expectEqual(@as(usize, 1), asked);
    try testing.expectEqual(@as(usize, 1), s.requests);
    release(0, 7);
    try testing.expect(s.lookup(holdProvider, .{ .ext = "txt" }, row_side) == null); // not before the merge
    try testing.expect(s.merge());
    const r = s.lookup(holdProvider, .{ .ext = "txt" }, row_side).?;
    try testing.expectEqual(@as(u32, 2), r.px.width);
    try testing.expectEqual(@as(u8, 7), r.px.bgra[3]);
    try testing.expectEqual(@as(usize, 1), asked);
}

test "no provider: nothing is asked, nothing is made" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    try testing.expect(s.lookup(null, .{ .ext = "txt" }, row_side) == null);
    try testing.expect(s.lookup(null, .folder, row_side) == null);
    try testing.expectEqual(@as(usize, 0), s.count());
    try testing.expectEqual(@as(usize, 0), s.requests);
}

test "keys: folders once, sizes apart, paths one each, long extensions and paths refused" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    defer releaseRest();
    for (0..50) |_| _ = s.lookup(holdProvider, .folder, row_side);
    try testing.expectEqual(@as(usize, 1), asked);
    _ = s.lookup(holdProvider, .folder, large_side); // another size is another picture
    try testing.expectEqual(@as(usize, 2), asked);
    _ = s.lookup(holdProvider, .{ .path = "/Applications/A.app" }, row_side);
    _ = s.lookup(holdProvider, .{ .path = "/Applications/B.app" }, row_side);
    _ = s.lookup(holdProvider, .{ .path = "/Applications/A.app" }, row_side);
    try testing.expectEqual(@as(usize, 4), asked);
    const long_ext: [max_ext + 1]u8 = @splat('x');
    const long_path: [max_key + 1]u8 = @splat('p');
    _ = s.lookup(holdProvider, .{ .ext = &long_ext }, row_side);
    _ = s.lookup(holdProvider, .{ .path = &long_path }, row_side);
    _ = s.lookup(holdProvider, .{ .ext = "" }, row_side);
    try testing.expectEqual(@as(usize, 4), asked);
}

test "a failure is remembered: the key is not asked again" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    try testing.expect(s.lookup(failProvider, .{ .ext = "zzz" }, row_side) == null);
    _ = s.merge();
    for (0..20) |_| try testing.expect(s.lookup(failProvider, .{ .ext = "zzz" }, row_side) == null);
    _ = s.merge();
    try testing.expect(s.lookup(failProvider, .{ .ext = "zzz" }, row_side) == null);
    try testing.expectEqual(@as(usize, 1), asked);
}

test "the cache is bounded; the least recently used go first" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    var name: [32]u8 = undefined;
    for (0..max_slots + 40) |i| {
        const e = try std.fmt.bufPrint(&name, "e{d}", .{i});
        _ = s.lookup(instantProvider, .{ .ext = e }, row_side);
        _ = s.merge();
        _ = s.merge(); // (the answer is in the inbox until a merge, evicted at the one after)
    }
    try testing.expect(s.count() <= max_slots);
    const before = asked;
    var e = try std.fmt.bufPrint(&name, "e{d}", .{max_slots + 39});
    try testing.expect(s.lookup(instantProvider, .{ .ext = e }, row_side) != null); // the newest is kept
    try testing.expectEqual(before, asked);
    e = try std.fmt.bufPrint(&name, "e{d}", .{0});
    try testing.expect(s.lookup(instantProvider, .{ .ext = e }, row_side) == null); // the oldest is gone
    try testing.expectEqual(before + 1, asked);
}

test "the cache is bounded in bytes too" {
    const Big = struct {
        fn provide(key: Key, side: u32, done: Done) void {
            _ = key;
            _ = side;
            const px = testing.allocator.alloc(u8, 512 * 512 * 4) catch return done.finish(null);
            defer testing.allocator.free(px);
            @memset(px, 9);
            done.finish(.{ .bgra = px, .width = 512, .height = 512 });
        }
    };
    const s = try Shared.create(testing.allocator);
    defer s.close();
    var name: [32]u8 = undefined;
    for (0..20) |i| {
        const e = try std.fmt.bufPrint(&name, "big{d}", .{i});
        _ = s.lookup(Big.provide, .{ .ext = e }, large_side);
        _ = s.merge();
    }
    try testing.expect(s.bytes <= max_bytes);
    try testing.expect(s.count() < 20);
}

test "at most max_in_flight requests are out; the rest are asked after one is answered" {
    reset();
    const s = try Shared.create(testing.allocator);
    defer s.close();
    defer releaseRest();
    var name: [32]u8 = undefined;
    for (0..max_in_flight + 5) |i| {
        const e = try std.fmt.bufPrint(&name, "k{d}", .{i});
        _ = s.lookup(holdProvider, .{ .ext = e }, row_side);
    }
    try testing.expectEqual(max_in_flight, asked);
    try testing.expectEqual(max_in_flight, s.count()); // the refused ones made no slot
    release(0, 1);
    _ = s.merge();
    // The next frame asks the key that was refused (and only one fits).
    for (0..max_in_flight + 5) |i| {
        const e = try std.fmt.bufPrint(&name, "k{d}", .{i});
        _ = s.lookup(holdProvider, .{ .ext = e }, row_side);
    }
    try testing.expectEqual(max_in_flight + 1, asked);
}

test "a model that goes away with requests in flight leaves nothing behind" {
    reset();
    const s = try Shared.create(testing.allocator);
    _ = s.lookup(holdProvider, .{ .ext = "late" }, row_side);
    _ = s.lookup(holdProvider, .folder, row_side);
    release(1, 3); // one answer waits in the inbox when the model closes
    s.close(); // the other provider still holds its Done
    release(0, 1); // frees the shared state (the leak checker proves it)
}
