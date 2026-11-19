//! Folder reads off the main thread: the injectable runner behind `Config.listing`, in the shape
//! of `palette_index`'s (a `Runner` is handed each `Job`; main.zig's is a thread, tests pass one
//! that runs it at once or keeps it until they release it) and `thumbs`' (the answer is merged at
//! the start of the next pass, never into live state from a worker).
//!
//! A `Job` reads a list of folders with `Listing.loadFolder` and then delivers. The two halves
//! are separate on purpose:
//!   - `read` is the ONLY part that may run on a worker thread. It touches the job's own memory
//!     (its path copies and its result slice) and the allocator (the app's `smp_allocator` is
//!     thread-safe), calls the libc-based lister (no shared state), and reads one atomic flag
//!     (`Shared.dead`) to skip the work when the model is already gone. It never sees the model,
//!     a tab, a pane or a listing.
//!   - `deliver` runs on the MAIN thread (a worker hops there with `objc.dispatchMain`, see
//!     `system_listing.zig`; a test runner is already there). It appends the result to the
//!     inbox, which only the main thread touches, and wakes a frame. `Model.applyPending` merges
//!     the inbox at the start of the next pass (`listing_apply.drain`).
//! So nothing needs a lock. `Shared` lives on the heap and counts the jobs in flight: a model
//! that goes away while a job still runs marks it dead, and the last `deliver` frees it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Listing = @import("listing.zig").Listing;
const inbox = @import("listing_inbox.zig");
const watch = @import("watch.zig");

pub const Entry = inbox.Entry;
pub const Waker = watch.Waker;

/// How `Config.listing` turns on the asynchronous listing (null there: everything reads inline).
pub const Config = struct {
    /// Runs each job: on a thread (main.zig), at once (`runNow`) or later (tests).
    runner: Runner,
    /// Jobs in flight at once; a request beyond that waits (the newest of its kind replaces an
    /// older one that is still waiting), so quick repeated navigation cannot pile up threads.
    max_running: usize = 4,
};

/// What runs a `Job`: it calls `job.run()`, or `job.read()` on a thread followed by `job.deliver()`
/// on the main thread.
pub const Runner = *const fn (job: *Job) void;

/// What the loader and its jobs share. Main thread only, except `dead`.
pub const Shared = struct {
    gpa: Allocator,
    /// Jobs handed to the runner whose `deliver` has not run yet.
    in_flight: usize = 0,
    dead: std.atomic.Value(bool) = .init(false),
    waker: ?Waker = null,
    /// Delivered results, oldest first, merged by `listing_apply.drain`.
    arrivals: std.ArrayList(Arrival) = .empty,

    pub fn create(gpa: Allocator) Allocator.Error!*Shared {
        const s = try gpa.create(Shared);
        s.* = .{ .gpa = gpa };
        return s;
    }

    /// The model is going away: drops what was delivered. With jobs in flight the object stays
    /// (dead) until the last one delivers.
    pub fn close(self: *Shared) void {
        self.dead.store(true, .release);
        self.waker = null;
        for (self.arrivals.items) |a| inbox.freeEntries(self.gpa, a.entries);
        self.arrivals.deinit(self.gpa);
        self.arrivals = .empty;
        if (self.in_flight == 0) self.gpa.destroy(self);
    }

    pub fn setWaker(self: *Shared, w: ?Waker) void {
        self.waker = w;
    }
};

/// A finished job's folders, for the request numbered `seq`.
pub const Arrival = struct {
    seq: u32,
    entries: []Entry,
};

pub const Job = struct {
    gpa: Allocator,
    shared: *Shared,
    seq: u32,
    /// The folders to read (owned; moved into `entries` by `read`).
    paths: [][]u8,
    entries: []Entry = &.{},

    /// Reads every folder. Safe on a worker thread (see the file's comment).
    pub fn read(job: *Job) void {
        const gpa = job.gpa;
        if (job.shared.dead.load(.acquire)) return; // the model is gone: nobody wants this
        const out = gpa.alloc(Entry, job.paths.len) catch return; // no entries: the landing reads inline
        for (job.paths, out) |path, *e| {
            e.* = .{ .path = path, .result = if (Listing.loadFolder(gpa, path)) |items| .{ .items = items } else |err| .{ .err = err } };
        }
        gpa.free(job.paths);
        job.paths = &.{};
        job.entries = out;
    }

    /// Main thread: hands the result to the inbox (or frees it if the model is gone), wakes a
    /// frame and frees the job.
    pub fn deliver(job: *Job) void {
        const gpa = job.gpa;
        const s = job.shared;
        defer {
            for (job.paths) |p| gpa.free(p); // `read` was skipped
            gpa.free(job.paths);
            gpa.destroy(job);
        }
        s.in_flight -= 1;
        if (s.dead.load(.acquire)) {
            inbox.freeEntries(gpa, job.entries);
            if (s.in_flight == 0) gpa.destroy(s);
            return;
        }
        // Room was reserved when the job started (`Loader.start`), so this cannot fail.
        s.arrivals.appendAssumeCapacity(.{ .seq = job.seq, .entries = job.entries });
        if (s.waker) |w| w.wake(w.ctx);
    }

    /// `read` then `deliver`, on the calling thread (the main thread: tests, `runNow`).
    pub fn run(job: *Job) void {
        job.read();
        job.deliver();
    }
};

/// A runner that reads at once, on the calling thread (the model's own: only for tests).
pub fn runNow(job: *Job) void {
    job.run();
}
