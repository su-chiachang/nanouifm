//! Persistence (SPEC 14): favorites, pinned, the pane layout tree with each pane's tabs, shown
//! tab and view mode, hidden files and the sidebar's visibility are kept in the core's
//! `StateStore` (`<dir>/state.json`). The store is injected (`Config.store`: main.zig's real one
//! at ~/Library/Application Support/nanofm or $NANOFM_STATE_DIR, a temp directory in tests; null:
//! nothing is read or written).
//!
//! Restore (`restore`, at the end of `Model.init`): what `store.load()` gives (the file, or the
//! first-launch defaults when it is missing or corrupt) with folders that are gone skipped: a tab
//! whose folder is gone is dropped, a pane left without tabs is dropped (the layout closes over
//! it), the shown tab is the saved one, else the nearest one before it that survived (clamped to
//! what is left). If no pane survives the model keeps the one `Config.start_path` made.
//!
//! Saving: every pass that ran actions compares the model with what the file holds
//! (`noteChange`); a difference sets a deadline 400 ms past the frame clock, moved on by each
//! further change (a debounce). `tick`, at the start of each pass, saves once the clock passes it
//! and, while one is pending, asks the window for a frame at the deadline (`Context.frameIn`, a
//! timer: no polling). `flush` saves at once (the app quitting).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const state_store = @import("../core/state_store.zig");
const fs = @import("../core/file_ops_fs.zig");
const model_mod = @import("model.zig");
const Model = model_mod.Model;
const Pane = @import("pane.zig").Pane;
const ViewMode = @import("pane.zig").ViewMode;
const pane_sizes = @import("pane_sizes.zig");
const sidebar_model = @import("sidebar_model.zig");

pub const Store = state_store.StateStore;
const PersistedState = state_store.PersistedState;
const PersistedPane = state_store.PersistedPane;

/// How long a change waits for further ones before it is written (seconds of the frame clock).
pub const delay: f64 = 0.4;

pub const State = struct {
    /// Borrowed from `Config.store`; null: nothing is persisted.
    store: ?*state_store.StateStore = null,
    /// What the file holds: as loaded, then as last saved.
    last: ?PersistedState = null,
    /// The newest state seen that differs from `last` (so a pass that changed nothing persisted
    /// does not move the deadline).
    noted: ?PersistedState = null,
    /// The frame-clock time at which the pending change is written.
    due: ?f64 = null,
    /// How many times the file has been written.
    saves: u32 = 0,

    pub fn deinit(self: *State, gpa: Allocator) void {
        if (self.last) |*l| l.deinit(gpa);
        if (self.noted) |*n| n.deinit(gpa);
        self.* = .{};
    }
};

/// $NANOFM_STATE_DIR when it is set and not empty, else ~/Library/Application Support/nanofm.
/// Pure: main.zig reads the environment. The result is owned by the caller.
pub fn stateDir(gpa: Allocator, home: []const u8, override: ?[]const u8) Allocator.Error![]u8 {
    if (override) |o| if (o.len > 0) return gpa.dupe(u8, o);
    return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanofm" });
}

// ---- model -> state ----

fn viewModeOf(mode: ViewMode) state_store.ViewMode {
    return switch (mode) {
        .list => .list,
        .column => .column,
    };
}

fn paneOf(m: *Model, id: *const u32) Allocator.Error!PersistedPane {
    const p = &m.panes.items[m.paneIndex(id.*).?];
    var out: PersistedPane = .{ .selected_tab = p.active, .view_mode = viewModeOf(p.view_mode) };
    errdefer out.deinit(m.gpa);
    for (p.tabs.items) |*t| try out.addTab(m.gpa, t.path());
    return out;
}

/// The model as the state file has it (owned by the caller).
pub fn snapshot(m: *Model) Allocator.Error!PersistedState {
    var fav = try m.sidebar.entries(.favorites);
    errdefer state_store.model.deinitEntries(m.gpa, &fav);
    var pin = try m.sidebar.entries(.pinned);
    errdefer state_store.model.deinitEntries(m.gpa, &pin);
    var layout = try m.layout.map(m.gpa, PersistedPane, m, paneOf);
    errdefer layout.deinit(m.gpa);
    return .{ .favorites = fav, .pinned = pin, .layout = layout, .show_hidden = m.show_hidden, .sidebar_visible = m.sidebar_visible };
}

// ---- saving ----

/// After a pass that ran actions: is the model different from the file? Then the write is due
/// `delay` after the last such change; back to what the file holds, nothing is due.
pub fn noteChange(m: *Model) void {
    const ps = &m.persist;
    if (ps.store == null) return;
    var snap = snapshot(m) catch return;
    if (ps.last) |*l| if (l.eql(&snap)) {
        snap.deinit(m.gpa);
        if (ps.noted) |*n| n.deinit(m.gpa);
        ps.noted = null;
        ps.due = null;
        return;
    };
    if (ps.noted) |*n| {
        if (n.eql(&snap)) { // nothing new since the last change: the deadline stands
            snap.deinit(m.gpa);
            return;
        }
        n.deinit(m.gpa);
    }
    ps.noted = snap;
    ps.due = m.clock + delay;
}

/// The start of a pass (after the actions): writes the file when the deadline has passed, else
/// asks for a frame at it.
pub fn tick(m: *Model, c: *ui.Context) void {
    const due = m.persist.due orelse return;
    if (m.clock >= due) return flush(m);
    c.frameIn(@floatCast(due - m.clock));
}

/// Writes the file now if a change is pending (the deadline, and the app quitting).
pub fn flush(m: *Model) void {
    const ps = &m.persist;
    const store = ps.store orelse return;
    // Only what changed since launch or the last write is written: a state that merely lost the
    // tabs of an unmounted volume at restore stays as the file has it until the user changes something.
    if (ps.due == null and ps.noted == null) return;
    ps.due = null;
    if (ps.noted) |*n| n.deinit(m.gpa);
    ps.noted = null;
    var snap = snapshot(m) catch return;
    if (ps.last) |*l| if (l.eql(&snap)) {
        snap.deinit(m.gpa);
        return;
    };
    store.save(&snap) catch |e| {
        snap.deinit(m.gpa);
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Couldn't save window state: {s}.", .{@errorName(e)}) catch "Couldn't save window state.";
        m.raise(text) catch {};
        return;
    };
    if (ps.last) |*l| l.deinit(m.gpa);
    ps.last = snap;
    ps.saves += 1;
}

// ---- state -> model ----

const Build = struct {
    m: *Model,
    panes: std.ArrayList(Pane) = .empty,

    fn discard(self: *Build) void {
        for (self.panes.items) |*p| p.deinit();
        self.panes.deinit(self.m.gpa);
    }

    /// One saved pane as a model pane: null when none of its folders is left.
    fn pane(self: *Build, pp: *const PersistedPane) Allocator.Error!?u32 {
        const m = self.m;
        var made: ?Pane = null;
        errdefer if (made) |*p| p.deinit();
        var shown: usize = 0;
        for (pp.tabs.items, 0..) |path, i| {
            if (fs.checkDirectory(path) != .directory) continue;
            const folder = try model_mod.normalize(m.gpa, path);
            defer m.gpa.free(folder);
            if (made) |*p| {
                var o = p.opts(m.show_hidden);
                o.loader = m.loader.ifAsync();
                _ = try p.addTabWith(folder, m.nextId(), o, p.tabs.items.len - 1, false);
            } else {
                made = try Pane.init(m.gpa, folder, .{ .show_hidden = m.show_hidden, .loader = m.loader.ifAsync() }, .{ .pane = m.nextId(), .tab = m.nextId() });
            }
            if (i <= pp.selected_tab) shown = made.?.tabs.items.len - 1;
        }
        var p = made orelse return null;
        p.active = shown;
        p.view_mode = switch (pp.view_mode) {
            .list => .list,
            .column => .column,
        };
        try self.panes.append(m.gpa, p);
        made = null;
        return p.id;
    }
};

/// Loads the store and makes the model what it says (see the file's comment). Called by
/// `Model.init` before anything is drawn.
pub fn restore(m: *Model) Allocator.Error!void {
    const store = m.persist.store orelse return;
    var st = try store.load();
    var kept = false;
    defer if (!kept) st.deinit(m.gpa);

    const fav = try sidebar_model.itemsOf(m.gpa, st.favorites.items);
    defer m.gpa.free(fav);
    const pin = try sidebar_model.itemsOf(m.gpa, st.pinned.items);
    defer m.gpa.free(pin);

    var b: Build = .{ .m = m };
    errdefer b.discard();
    var tree = (try st.layout.compactMapLeaves(m.gpa, u32, &b, Build.pane)) orelse {
        // No folder of any pane is left: the model keeps its first pane.
        try m.sidebar.replaceEntries(fav, pin);
        m.show_hidden = st.show_hidden;
        m.sidebar_visible = st.sidebar_visible;
        m.persist.last = st;
        kept = true;
        return;
    };
    errdefer tree.deinit(m.gpa);
    var sizes: pane_sizes.Sizes = .{};
    errdefer sizes.deinit(m.gpa);
    try sizes.reset(m.gpa, &tree);
    try m.retired_panes.ensureUnusedCapacity(m.gpa, m.panes.items.len);
    try m.sidebar.replaceEntries(fav, pin);

    // Commit: nothing below fails.
    m.retired_panes.appendSliceAssumeCapacity(m.panes.items);
    m.panes.deinit(m.gpa);
    m.panes = b.panes;
    m.layout.deinit(m.gpa);
    m.layout = tree;
    m.sizes.deinit(m.gpa);
    m.sizes = sizes;
    m.focused = 0;
    m.show_hidden = st.show_hidden;
    m.sidebar_visible = st.sidebar_visible;
    m.persist.last = st;
    kept = true;
}

const testing = std.testing;

test "the state directory: the override, else Application Support" {
    const a = try stateDir(testing.allocator, "/Users/me", "/tmp/elsewhere");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/tmp/elsewhere", a);
    for ([_]?[]const u8{ null, "" }) |none| {
        const d = try stateDir(testing.allocator, "/Users/me", none);
        defer testing.allocator.free(d);
        try testing.expectEqualStrings("/Users/me/Library/Application Support/nanofm", d);
    }
}
