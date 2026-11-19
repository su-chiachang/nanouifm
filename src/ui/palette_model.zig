//! The command palette's state (UI-only: it lives in `Model.view_state.palette`): whether it is
//! open, the field's text, the rows answering that text, the highlighted row and the file index.
//! No drawing (`palette_view.zig`), no row building (`palette_rows.zig`), no running
//! (`palette_exec.zig`).
//!
//! The rows of an answer live in one arena (`Results`). nanoui keeps pointers to the strings a
//! frame drew until the next one, so a replaced answer is never freed on the spot: it is retired
//! and freed at the next `Model.applyPending`; and a closed palette keeps its last answer for the
//! fade-out, until it is opened again.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const CommandId = @import("command_id.zig").Id;
const palette_index = @import("palette_index.zig");

/// Where a chosen folder or file goes: the focused pane (Return), a new tab (Cmd+Return) or a
/// pane docked beside it (Opt+Return).
pub const OpenTarget = enum { here, new_tab, split };

/// `Action.palette_open`'s payload (the path is owned by the queue).
pub const Open = struct {
    path: []const u8,
    is_dir: bool,
    target: OpenTarget,
};

pub const Kind = enum { header, location, command, file };

pub const Row = struct {
    kind: Kind,
    /// A section's name, a command's title, or a folder's or file's name.
    title: []const u8,
    /// Commands: their menu; folders and files: where they are (abbreviated, "~/Documents").
    subtitle: []const u8 = "",
    /// Commands: the shortcut as menus write it.
    shortcut: []const u8 = "",
    /// Folders and files: the absolute path.
    path: []const u8 = "",
    /// An SF Symbol.
    icon: []const u8 = "",
    is_dir: bool = false,
    command: ?CommandId = null,
    /// False for a command that wouldn't do anything now: dimmed, never chosen.
    enabled: bool = true,

    /// Whether the keyboard can land on it.
    pub fn selectable(r: Row) bool {
        return r.kind != .header and r.enabled;
    }
};

/// One answer: its rows, in the arena that owns every string of them.
pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,

    pub fn deinit(self: *Results) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    open: bool = false,
    buf: ui.TextBuffer = .{},
    /// The text `results` answers (owned; "" for the empty query).
    query: []u8 = &.{},
    results: ?Results = null,
    /// Answers replaced since the last pass: freed by `freeRetired`.
    retired: std.ArrayList(Results) = .empty,
    /// The highlighted row (an index of the answer's rows), if any can be chosen.
    selected: ?usize = null,
    /// The list scrolls the highlighted row into sight in the next frame.
    reveal: bool = false,
    /// `index.generation()` when the answer was made: a finished crawl asks for a new answer.
    seen_generation: u32 = 0,
    index: palette_index.Index = .{},

    pub fn deinit(self: *State, gpa: Allocator) void {
        self.freeRetired();
        self.retired.deinit(gpa);
        if (self.results) |*r| r.deinit();
        gpa.free(self.query);
        self.buf.deinit();
        self.index.deinit();
        self.* = .{};
    }

    /// Frees the answers replaced earlier (the frame that drew them is over).
    pub fn freeRetired(self: *State) void {
        for (self.retired.items) |*r| r.deinit();
        self.retired.clearRetainingCapacity();
    }

    pub fn rows(self: *const State) []const Row {
        return if (self.results) |r| r.rows else &.{};
    }

    /// Makes `fresh` the answer to `query` (copied); the old answer is retired. The first row that
    /// can be chosen is highlighted.
    pub fn adopt(self: *State, gpa: Allocator, query: []const u8, fresh: Results) Allocator.Error!void {
        const q = try gpa.dupe(u8, query);
        errdefer gpa.free(q);
        if (self.results) |old| try self.retired.append(gpa, old);
        gpa.free(self.query);
        self.query = q;
        self.results = fresh;
        self.selected = null;
        for (fresh.rows, 0..) |r, i| if (r.selectable()) {
            self.selected = i;
            break;
        };
        self.reveal = true;
    }

    /// Up (-1) and Down (+1): the next row that can be chosen, wrapping around.
    pub fn move(self: *State, delta: i32) void {
        const rs = self.rows();
        const n: i32 = @intCast(rs.len);
        if (n == 0) return;
        var i: i32 = if (self.selected) |s| @intCast(s) else (if (delta > 0) -1 else n);
        var tries: i32 = 0;
        while (tries < n) : (tries += 1) {
            i = @mod(i + delta, n);
            if (rs[@intCast(i)].selectable()) {
                self.selected = @intCast(i);
                self.reveal = true;
                return;
            }
        }
    }

    pub fn selectedRow(self: *const State) ?Row {
        const s = self.selected orelse return null;
        const rs = self.rows();
        return if (s < rs.len) rs[s] else null;
    }
};
