//! Watches one directory (non-recursive) for create / delete / rename and calls
//! `onChange(ctx)` on a dispatch queue, debounced (~150 ms) so a burst of changes
//! gives one call. Nothing polls: a libdispatch VNODE source on an O_EVTONLY fd
//! reports changes, and a one-shot timer source (re-armed by every event) does
//! the debounce.
//!
//! The queue is injectable: production passes nothing and gets the main queue
//! (the UI thread); a test passes a private serial queue (a test run has no
//! main run loop). Every handler runs on that queue.
//!
//! macOS only (libdispatch + O_EVTONLY); elsewhere `start` does nothing.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("nanoui").objc;

pub const Queue = objc.dispatch_queue_t;

/// Called on the watcher's queue after the directory changed (and was quiet for `debounce_ns`).
pub const Callback = *const fn (ctx: ?*anyopaque) void;

pub const debounce_ns: u64 = 150 * std.time.ns_per_ms;

pub const Options = struct {
    /// Queue the callback runs on. Null: the main queue.
    queue: ?Queue = null,
    /// Quiet time after the last event before the callback runs.
    debounce_ns: u64 = debounce_ns,
};

// ---- libdispatch ----------------------------------------------------------

const Source = *opaque {};
const Handler = *const fn (?*anyopaque) callconv(.c) void;
const is_mac = builtin.os.tag.isDarwin();

extern "c" var _dispatch_source_type_vnode: opaque {};
extern "c" var _dispatch_source_type_timer: opaque {};
extern "c" fn dispatch_source_create(kind: *anyopaque, handle: usize, mask: usize, queue: Queue) ?Source;
extern "c" fn dispatch_set_context(obj: *anyopaque, ctx: ?*anyopaque) void;
extern "c" fn dispatch_source_set_event_handler_f(src: Source, handler: Handler) void;
extern "c" fn dispatch_source_set_cancel_handler_f(src: Source, handler: Handler) void;
extern "c" fn dispatch_source_set_timer(src: Source, start: u64, interval: u64, leeway: u64) void;
extern "c" fn dispatch_resume(obj: *anyopaque) void;
extern "c" fn dispatch_source_cancel(src: Source) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) ?Queue;
extern "c" fn dispatch_sync_f(queue: Queue, ctx: ?*anyopaque, work: Handler) void;

const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);
const DISPATCH_VNODE_DELETE: usize = 0x1;
const DISPATCH_VNODE_WRITE: usize = 0x2;
const DISPATCH_VNODE_EXTEND: usize = 0x4;
const DISPATCH_VNODE_ATTRIB: usize = 0x8;
const DISPATCH_VNODE_RENAME: usize = 0x20;
const vnode_mask = DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
    DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_ATTRIB;
const O_EVTONLY: u32 = 0x8000;

/// The main queue: where the UI runs.
pub fn mainQueue() Queue {
    return objc.mainQueue();
}

/// A new private serial queue (for tests); release it with `releaseQueue`.
pub fn createSerialQueue(label: [*:0]const u8) ?Queue {
    return dispatch_queue_create(label, null);
}

pub fn releaseQueue(q: Queue) void {
    objc.dispatch_release(q);
}

fn nop(_: ?*anyopaque) callconv(.c) void {}

/// Returns once everything already queued on `q` has run (never call it from `q`).
pub fn drainQueue(q: Queue) void {
    dispatch_sync_f(q, null, nop);
}

// ---- state shared with the handlers ---------------------------------------

/// Heap state one `start` creates. The handlers hold it by pointer, so it lives
/// until both sources' cancel handlers have run (after the last event handler),
/// whatever happens to the `DirWatcher` value in the meantime.
const Shared = struct {
    gpa: std.mem.Allocator,
    ctx: ?*anyopaque,
    on_change: Callback,
    debounce_ns: u64,
    fd: c_int,
    vnode: Source,
    timer: Source,
    active: std.atomic.Value(bool) = .init(true),
    refs: std.atomic.Value(u8) = .init(2),
};

/// Test hook: called after a `Shared` is freed, on the watcher's queue.
pub var released_hook: ?*const fn () void = null;

fn vnodeEvent(raw: ?*anyopaque) callconv(.c) void {
    const s: *Shared = @ptrCast(@alignCast(raw.?));
    if (!s.active.load(.acquire)) return;
    // (Re)arm the one-shot timer: the callback runs once events stop for the debounce time.
    dispatch_source_set_timer(s.timer, dispatch_time(0, @intCast(s.debounce_ns)), DISPATCH_TIME_FOREVER, 1 * std.time.ns_per_ms);
}

fn timerFired(raw: ?*anyopaque) callconv(.c) void {
    const s: *Shared = @ptrCast(@alignCast(raw.?));
    if (!s.active.load(.acquire)) return;
    s.on_change(s.ctx);
}

fn vnodeCanceled(raw: ?*anyopaque) callconv(.c) void {
    const s: *Shared = @ptrCast(@alignCast(raw.?));
    _ = std.c.close(s.fd);
    unref(s);
}

fn timerCanceled(raw: ?*anyopaque) callconv(.c) void {
    unref(@ptrCast(@alignCast(raw.?)));
}

fn unref(s: *Shared) void {
    if (s.refs.fetchSub(1, .acq_rel) != 1) return;
    objc.dispatch_release(s.vnode);
    objc.dispatch_release(s.timer);
    s.gpa.destroy(s);
    if (released_hook) |h| h();
}

// ---- the watcher ----------------------------------------------------------

pub const DirWatcher = struct {
    gpa: std.mem.Allocator,
    path: [:0]u8,
    ctx: ?*anyopaque,
    on_change: Callback,
    opts: Options,
    shared: ?*Shared = null,

    /// Does not start watching; call `start`. `path` is copied.
    pub fn init(gpa: std.mem.Allocator, path: []const u8, ctx: ?*anyopaque, on_change: Callback, opts: Options) !DirWatcher {
        return .{ .gpa = gpa, .path = try gpa.dupeSentinel(u8, path, 0), .ctx = ctx, .on_change = on_change, .opts = opts };
    }

    /// Stops watching and frees the path. No callback runs after it returns
    /// (one already running on another thread may finish).
    pub fn deinit(w: *DirWatcher) void {
        w.stop();
        w.gpa.free(w.path);
        w.* = undefined;
    }

    pub fn isRunning(w: *const DirWatcher) bool {
        return w.shared != null;
    }

    /// Starts watching. Harmless when already running. If the directory cannot be
    /// opened (or off macOS) nothing is watched and `isRunning` stays false.
    pub fn start(w: *DirWatcher) void {
        if (comptime !is_mac) return;
        if (w.shared != null) return;
        const queue = w.opts.queue orelse mainQueue();
        const fd = std.c.open(w.path.ptr, @bitCast(O_EVTONLY));
        if (fd < 0) return;

        const s = w.gpa.create(Shared) catch {
            _ = std.c.close(fd);
            return;
        };
        const vnode = dispatch_source_create(@ptrCast(&_dispatch_source_type_vnode), @intCast(fd), vnode_mask, queue);
        const timer = dispatch_source_create(@ptrCast(&_dispatch_source_type_timer), 0, 0, queue);
        if (vnode == null or timer == null) {
            // Sources start suspended and must not be released that way: run them, cancel them.
            inline for (.{ vnode, timer }) |maybe| if (maybe) |src| {
                dispatch_resume(src);
                dispatch_source_cancel(src);
                objc.dispatch_release(src);
            };
            _ = std.c.close(fd);
            w.gpa.destroy(s);
            return;
        }
        s.* = .{ .gpa = w.gpa, .ctx = w.ctx, .on_change = w.on_change, .debounce_ns = w.opts.debounce_ns, .fd = fd, .vnode = vnode.?, .timer = timer.? };

        dispatch_set_context(s.vnode, s);
        dispatch_source_set_event_handler_f(s.vnode, vnodeEvent);
        dispatch_source_set_cancel_handler_f(s.vnode, vnodeCanceled);
        dispatch_set_context(s.timer, s);
        dispatch_source_set_event_handler_f(s.timer, timerFired);
        dispatch_source_set_cancel_handler_f(s.timer, timerCanceled);
        dispatch_source_set_timer(s.timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0); // idle until an event
        dispatch_resume(s.timer);
        dispatch_resume(s.vnode);
        w.shared = s;
    }

    /// Stops watching and drops a callback still waiting out its debounce.
    /// Harmless when not running; can be called again, and `start` can follow.
    pub fn stop(w: *DirWatcher) void {
        const s = w.shared orelse return;
        w.shared = null;
        s.active.store(false, .release);
        dispatch_source_cancel(s.timer);
        dispatch_source_cancel(s.vnode);
        // `s` is freed by the cancel handlers, once no handler can still touch it.
    }
};

// ---- tests ----------------------------------------------------------------

const testing = std.testing;
const Semaphore = objc.dispatch_semaphore_t;

fn semWait(sem: Semaphore, ms: u64) bool {
    return objc.dispatch_semaphore_wait(sem, dispatch_time(0, @intCast(ms * std.time.ns_per_ms))) == 0;
}

/// Pauses the test thread without polling.
fn sleepMs(ms: u64) void {
    const sem = objc.dispatch_semaphore_create(0);
    defer objc.dispatch_release(sem);
    _ = semWait(sem, ms);
}

const Probe = struct {
    count: std.atomic.Value(u32) = .init(0),
    sem: Semaphore,
    cb_thread: std.atomic.Value(std.Thread.Id) = .init(0),

    fn init() Probe {
        return .{ .sem = objc.dispatch_semaphore_create(0) };
    }
    fn deinit(p: *Probe) void {
        objc.dispatch_release(p.sem);
    }
    fn cb(raw: ?*anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(raw.?));
        p.cb_thread.store(std.Thread.getCurrentId(), .release);
        _ = p.count.fetchAdd(1, .acq_rel);
        _ = objc.dispatch_semaphore_signal(p.sem);
    }
    /// Waits (no polling) for the next callback.
    fn waitFire(p: *Probe, ms: u64) bool {
        return semWait(p.sem, ms);
    }
};

var released_sem: ?Semaphore = null;
fn onReleased() void {
    _ = objc.dispatch_semaphore_signal(released_sem.?);
}

/// A private queue, a scratch dir, and a release counter, for one test.
const Env = struct {
    q: Queue,
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init() !Env {
        var e: Env = undefined;
        e.q = createSerialQueue("nanofm.dir-watcher.test") orelse return error.NoQueue;
        e.tmp = testing.tmpDir(.{});
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try e.tmp.dir.realPath(testing.io, &buf);
        e.path = try testing.allocator.dupe(u8, buf[0..n]);
        released_sem = objc.dispatch_semaphore_create(0);
        released_hook = onReleased;
        return e;
    }
    /// `releases`: how many watcher starts must have been freed by now.
    fn deinit(e: *Env, releases: usize) void {
        for (0..releases) |_| { // all state freed: no leak
            if (!semWait(released_sem.?, 2000)) @panic("watcher state was not released");
        }
        released_hook = null;
        objc.dispatch_release(released_sem.?);
        released_sem = null;
        testing.allocator.free(e.path);
        e.tmp.cleanup();
        releaseQueue(e.q);
    }
    fn watcher(e: *Env, p: *Probe) !DirWatcher {
        return DirWatcher.init(testing.allocator, e.path, p, Probe.cb, .{ .queue = e.q });
    }
    fn write(e: *Env, name: []const u8) !void {
        try e.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = "hi" });
    }
};

test "fires on create, rename, delete and new folder, on the injected queue" {
    var env = try Env.init();
    defer env.deinit(1);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try env.watcher(&probe);
    defer w.deinit();
    w.start();
    try testing.expect(w.isRunning());

    try env.write("new.txt");
    try testing.expect(probe.waitFire(5000));
    try testing.expect(probe.cb_thread.load(.acquire) != std.Thread.getCurrentId());

    try env.tmp.dir.rename("new.txt", env.tmp.dir, "renamed.txt", testing.io);
    try testing.expect(probe.waitFire(5000));

    try env.tmp.dir.deleteFile(testing.io, "renamed.txt"); // own temp scaffolding
    try testing.expect(probe.waitFire(5000));

    try env.tmp.dir.createDir(testing.io, "sub", .default_dir);
    try testing.expect(probe.waitFire(5000));
}

test "debounces bursts into few callbacks" {
    var env = try Env.init();
    defer env.deinit(1);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try env.watcher(&probe);
    defer w.deinit();
    w.start();

    var name_buf: [32]u8 = undefined;
    for (0..20) |i| try env.write(try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}));
    try testing.expect(probe.waitFire(5000));
    sleepMs(500); // let a straggler show up
    const n = probe.count.load(.acquire);
    try testing.expect(n >= 1 and n <= 3);
}

test "stop is idempotent and silences callbacks; start twice and restart work" {
    var env = try Env.init();
    defer env.deinit(2);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try env.watcher(&probe);
    defer w.deinit();
    w.stop(); // before start: harmless
    w.start();
    w.start(); // double start: harmless
    w.stop();
    w.stop();
    try testing.expect(!w.isRunning());
    try env.write("after-stop.txt");
    sleepMs(600);
    try testing.expectEqual(@as(u32, 0), probe.count.load(.acquire));

    w.start(); // restart works
    try env.write("again.txt");
    try testing.expect(probe.waitFire(5000));
}

test "a pending callback is dropped by stop" {
    var env = try Env.init();
    defer env.deinit(1);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try env.watcher(&probe);
    defer w.deinit();
    w.start();
    try env.write("x.txt");
    sleepMs(50); // event delivered, debounce pending (150 ms)
    w.stop();
    sleepMs(500);
    try testing.expectEqual(@as(u32, 0), probe.count.load(.acquire));
}

test "deinit stops watching" {
    var env = try Env.init();
    defer env.deinit(1);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try env.watcher(&probe);
    w.start();
    w.deinit();
    try env.write("z.txt");
    sleepMs(500);
    try testing.expectEqual(@as(u32, 0), probe.count.load(.acquire));
}

test "a missing directory does not start, and is harmless" {
    var env = try Env.init();
    defer env.deinit(0);
    var probe = Probe.init();
    defer probe.deinit();
    var w = try DirWatcher.init(testing.allocator, "/nonexistent-nanofm-test-dir", &probe, Probe.cb, .{ .queue = env.q });
    defer w.deinit();
    w.start();
    try testing.expect(!w.isRunning());
    w.stop();
}

test "the production default queue is the main queue" {
    var probe = Probe.init();
    defer probe.deinit();
    var w = try DirWatcher.init(testing.allocator, "/nonexistent-nanofm-test-dir", &probe, Probe.cb, .{});
    defer w.deinit();
    try testing.expect(w.opts.queue == null); // start() resolves null to mainQueue()
    _ = mainQueue();
}
