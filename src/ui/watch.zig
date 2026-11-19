//! Live refresh: every folder a pane draws (the shown tab's folder, the folders opened in its
//! list, the columns of its column view) is watched with the core's `DirWatcher` (a libdispatch
//! VNODE source, debounced 150 ms, no polling). A watcher's callback runs on the main queue, the
//! UI thread: it only notes the folder as dirty and wakes a frame. The next `applyPending` reads
//! the tabs that show a dirty folder again, keeping selection and scroll, and then matches the
//! watchers to what is drawn now, so navigating, opening and closing tabs and panes need no
//! hooks of their own.
//!
//! Which backend runs is injected (`Config.watch`): `.off` does nothing (the default, snapshots),
//! `.manual` keeps the same bookkeeping without the operating system, so a test fires a change
//! itself with `fire`, and `.system` is the real thing (main.zig only).
//!
//! The reads go through the model's loader when listing is asynchronous (`Config.listing`):
//! the tab keeps its selection, scroll and rows until the new listing lands (`listing_apply.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const dir_watcher = @import("../core/dir_watcher.zig");
const Model = @import("model.zig").Model;
const refresh = @import("file_refresh.zig");

pub const Mode = enum { off, manual, system };

pub const Waker = @typeInfo(@FieldType(ui.Context, "waker")).optional.child;

/// What the callbacks reach: on the heap, so its address outlives moves of the model.
const Shared = struct {
    gpa: Allocator,
    /// Folders that changed since the last refresh (owned paths).
    dirty: std.ArrayList([]u8) = .empty,
    waker: ?Waker = null,

    fn mark(s: *Shared, path: []const u8) void {
        for (s.dirty.items) |d| if (std.mem.eql(u8, d, path)) return;
        const copy = s.gpa.dupe(u8, path) catch return;
        s.dirty.append(s.gpa, copy) catch {
            s.gpa.free(copy);
            return;
        };
        if (s.waker) |w| w.wake(w.ctx);
    }
};

const Entry = struct {
    shared: *Shared,
    path: []u8,
    /// Null in manual mode.
    dw: ?dir_watcher.DirWatcher = null,
};

fn onChange(ctx: ?*anyopaque) void {
    const e: *Entry = @ptrCast(@alignCast(ctx.?));
    e.shared.mark(e.path);
}

pub const Watchers = struct {
    gpa: Allocator,
    mode: Mode,
    shared: ?*Shared = null,
    entries: std.ArrayList(*Entry) = .empty,
    /// The tabs that were shown at the last reconcile (ids); a tab shown for the first time is
    /// read again, since nothing was watching its folder while it was hidden.
    shown: std.ArrayList(u32) = .empty,
    seen_first: bool = false,
    /// Handed to the callbacks' shared state when that is made.
    waker: ?Waker = null,

    pub fn init(gpa: Allocator, mode: Mode) Watchers {
        return .{ .gpa = gpa, .mode = mode };
    }

    pub fn deinit(self: *Watchers) void {
        for (self.entries.items) |e| self.destroy(e);
        self.entries.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        if (self.shared) |s| {
            for (s.dirty.items) |d| self.gpa.free(d);
            s.dirty.deinit(self.gpa);
            self.gpa.destroy(s);
        }
    }

    fn destroy(self: *Watchers, e: *Entry) void {
        if (e.dw) |*w| w.deinit();
        self.gpa.free(e.path);
        self.gpa.destroy(e);
    }

    /// Lets the callbacks ask for a frame (the context's waker; the model hands it over).
    pub fn setWaker(self: *Watchers, w: ?Waker) void {
        if (self.shared) |s| s.waker = w;
        self.waker = w;
    }

    fn sharedState(self: *Watchers) Allocator.Error!*Shared {
        if (self.shared) |s| return s;
        const s = try self.gpa.create(Shared);
        s.* = .{ .gpa = self.gpa, .waker = self.waker };
        self.shared = s;
        return s;
    }

    /// How many folders are watched now.
    pub fn count(self: *const Watchers) usize {
        return self.entries.items.len;
    }

    pub fn isWatching(self: *const Watchers, path: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.path, path)) return true;
        return false;
    }

    /// A change in `path`, as a watcher reports it: a test's trigger (`.manual`).
    pub fn fire(self: *Watchers, path: []const u8) Allocator.Error!void {
        (try self.sharedState()).mark(path);
    }

    /// Reads again the tabs that show a folder that changed. A rename in progress waits: the
    /// listing under a field being edited stays put.
    pub fn refreshDirty(self: *Watchers, m: *Model) Allocator.Error!bool {
        const s = self.shared orelse return false;
        if (s.dirty.items.len == 0 or m.rename != null) return false;
        defer {
            for (s.dirty.items) |d| self.gpa.free(d);
            s.dirty.clearRetainingCapacity();
        }
        try refresh.foldersLater(m, s.dirty.items);
        return true;
    }

    /// Starts and stops watchers so exactly the folders the panes draw are watched.
    pub fn reconcile(self: *Watchers, m: *Model) Allocator.Error!void {
        if (self.mode == .off) return;
        var want: std.ArrayList([]const u8) = .empty;
        defer want.deinit(self.gpa);
        var shown_now: std.ArrayList(u32) = .empty;
        defer shown_now.deinit(self.gpa);
        for (m.panes.items) |*p| {
            const tab = p.tab();
            try shown_now.append(self.gpa, tab.id);
            try addUnique(self.gpa, &want, tab.path());
            var it = tab.exp.set.keyIterator();
            while (it.next()) |k| try addUnique(self.gpa, &want, k.*);
            for (tab.col.columns.items) |c| try addUnique(self.gpa, &want, c.path);
        }
        // Stop what is no longer drawn.
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (contains(want.items, self.entries.items[i].path)) {
                i += 1;
            } else self.destroy(self.entries.swapRemove(i));
        }
        // Start what is new.
        for (want.items) |path| if (!self.isWatching(path)) try self.start(path);
        // A tab that just came into view missed what happened while it was hidden.
        if (self.seen_first) {
            for (m.panes.items) |*p| {
                const tab = p.tab();
                if (std.mem.indexOfScalar(u32, self.shown.items, tab.id) != null) continue;
                // (A tab whose first listing or navigation is still being read will be fresher than this.)
                if (!tab.listed or m.loader.has(tab.id, .reload) or m.loader.has(tab.id, .nav)) continue;
                try tab.reload(m.opts(p));
            }
        }
        self.seen_first = true;
        self.shown.clearRetainingCapacity();
        try self.shown.appendSlice(self.gpa, shown_now.items);
    }

    fn start(self: *Watchers, path: []const u8) Allocator.Error!void {
        const shared = try self.sharedState();
        const e = try self.gpa.create(Entry);
        errdefer self.gpa.destroy(e);
        e.* = .{ .shared = shared, .path = try self.gpa.dupe(u8, path) };
        errdefer self.gpa.free(e.path);
        try self.entries.append(self.gpa, e);
        if (self.mode == .system) {
            e.dw = dir_watcher.DirWatcher.init(self.gpa, path, e, onChange, .{}) catch null;
            if (e.dw) |*w| w.start();
        }
    }
};

fn contains(list: []const []const u8, path: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, path)) return true;
    return false;
}

fn addUnique(gpa: Allocator, list: *std.ArrayList([]const u8), path: []const u8) Allocator.Error!void {
    if (!contains(list.items, path)) try list.append(gpa, path);
}
