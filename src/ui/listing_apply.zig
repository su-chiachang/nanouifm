//! Where a finished read lands (the model's side of `listing_loader.zig`). `drain` merges the
//! inbox at the start of a pass (`Model.applyPending`; and again at its end, which only matters
//! to a runner that finishes inside the request), when nothing is being drawn. A result whose
//! request was replaced is dropped and freed; so is one whose tab went away. Otherwise the very
//! same synchronous code runs that would have read the folder (`Tab.visit`, `Tab.reload`,
//! `Tab.setExpanded`, the column operations), with the folders it needs already in a
//! `Preloaded`, and with the pane's CURRENT options (the sort order or the hidden-files setting
//! may have changed while the folder was being read).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const Pane = @import("pane.zig").Pane;
const Tab = @import("tab.zig").Tab;
const loader_mod = @import("listing_loader.zig");
const Loader = loader_mod.Loader;
const Pending = loader_mod.Pending;
const Arrival = @import("listing_runner.zig").Arrival;
const inbox = @import("listing_inbox.zig");
const column_ops = @import("column_ops.zig");
const refresh = @import("file_refresh.zig");
const persist = @import("persist.zig");

pub const Found = struct { pane: *Pane, tab: *Tab };

/// The live tab with this id, in whichever pane it is now (tabs move between panes).
pub fn findTab(m: *Model, id: u32) ?Found {
    for (m.panes.items) |*p| {
        for (p.tabs.items) |*t| if (t.id == id) return .{ .pane = p, .tab = t };
    }
    return null;
}

/// Merges what the workers delivered. True if something landed (the model changed).
pub fn drain(m: *Model) Allocator.Error!bool {
    const ld = m.loader;
    if (ld.draining) return false;
    ld.draining = true;
    defer ld.draining = false;
    const shared = ld.shared;
    var landed = false;
    var i: usize = 0;
    // A landing may start more requests (they append to the inbox, never reallocate it).
    errdefer {
        for (shared.arrivals.items[i..]) |a| inbox.freeEntries(m.gpa, a.entries);
        shared.arrivals.clearRetainingCapacity();
    }
    while (i < shared.arrivals.items.len) {
        const a = shared.arrivals.items[i];
        i += 1;
        if (try land(m, ld, a)) landed = true;
    }
    shared.arrivals.clearRetainingCapacity();
    try ld.pump(); // slots are free again
    if (landed) persist.noteChange(m);
    return landed;
}

/// One arrival. Consumes its entries. True if it changed a tab.
fn land(m: *Model, ld: *Loader, a: Arrival) Allocator.Error!bool {
    var pre: inbox.Preloaded = .{ .entries = a.entries };
    defer {
        ld.fallbacks += pre.misses;
        pre.deinit(m.gpa);
    }
    const idx = ld.indexOf(a.seq) orelse {
        ld.dropped += 1; // replaced by a newer request, or its tab's navigation moved on
        return false;
    };
    var p = ld.pending.orderedRemove(idx);
    defer p.deinit(m.gpa);
    const at = findTab(m, p.tab) orelse {
        ld.dropped += 1; // the tab (or its pane) was closed
        return false;
    };
    var o = m.opts(at.pane);
    o.pre = &pre;
    const tab = at.tab;
    const same_folder = std.mem.eql(u8, tab.path(), p.base);
    switch (p.intent) {
        .visit => |folder| {
            tab.visit(folder, o) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |le| {
                    try m.setNotice(folder, le); // history and location stay as they were
                    return true;
                },
            };
            m.clearNotice();
        },
        .back, .forward => {
            const back = p.intent == .back;
            const want = (if (back) tab.history.peekBack() else tab.history.peekForward()) orelse return false;
            if (!same_folder or !std.mem.eql(u8, want, p.paths[0])) return false; // history moved on
            if (!(if (back) try tab.back(o) else try tab.forward(o))) return false;
            m.clearNotice();
        },
        .reload => {
            if (!same_folder) return false;
            if (m.rename != null) { // the listing under a field being edited stays put: read again after
                try m.watch.fire(p.base);
                return false;
            }
            try tab.reload(o);
            if (p.select) |paths| {
                if (m.paneIndex(at.pane.id)) |pi| try refresh.select(m, pi, @ptrCast(paths));
            }
        },
        .expand => |folder| {
            if (!same_folder or tab.exp.isExpanded(folder)) return false;
            try tab.setExpanded(folder, true, o);
        },
        .col_after => |depth| {
            if (at.pane.view_mode != .column or depth >= tab.col.columns.items.len) return false;
            try column_ops.afterSelection(m.gpa, tab, o, depth);
        },
        .col_loc => |folder| {
            const last = tab.col.last() orelse return false;
            if (at.pane.view_mode != .column or !std.mem.eql(u8, last.path, folder)) return false;
            try column_ops.finishLocation(m.gpa, tab, o, folder);
        },
        .col_rebuild => {
            if (at.pane.view_mode != .column) return false;
            if (tab.col.last()) |l| if (std.mem.eql(u8, l.path, tab.path())) return false;
            try column_ops.rebuild(m.gpa, tab, o);
        },
    }
    return true;
}
