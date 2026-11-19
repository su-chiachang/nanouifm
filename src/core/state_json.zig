//! JSON for PersistedState, shaped like the Swift Codable output (sorted keys, pretty printed):
//!   {"favorites":[{"id":"UUID","title":"..","url":"file:///.."}], "layout":{"axis":"sideBySide",
//!    "children":[{"pane":{"selectedTab":0,"tabs":["file:///.."],"viewMode":"list"}}]},
//!    "pinned":[..], "showHidden":false, "sidebarVisible":true}
//! Decoding is tolerant like the Swift decoder: missing fields fall back to defaults, a bad `layout`
//! falls back to the legacy `panes` (+ `splitVertical`) keys. A wrong-typed field fails the whole decode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("state_model.zig");
const layout_tree = @import("layout_tree.zig");
const PersistedState = model.PersistedState;
const PersistedPane = model.PersistedPane;
const SidebarEntry = model.SidebarEntry;
const PaneTree = model.PaneTree;
const Value = std.json.Value;

pub const DecodeError = Allocator.Error || error{InvalidState};

// ---- encode ----

const Stringify = std.json.Stringify;

fn writeUrl(gpa: Allocator, s: *Stringify, path: []const u8) !void {
    const url = try model.urlFromPath(gpa, path);
    defer gpa.free(url);
    try s.write(url);
}

fn writeEntries(gpa: Allocator, s: *Stringify, list: []const SidebarEntry) !void {
    try s.beginArray();
    for (list) |e| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(&e.id.format());
        if (e.title) |t| {
            try s.objectField("title");
            try s.write(t);
        }
        try s.objectField("url");
        try writeUrl(gpa, s, e.path);
        try s.endObject();
    }
    try s.endArray();
}

fn writePane(gpa: Allocator, s: *Stringify, p: *const PersistedPane) !void {
    try s.beginObject();
    try s.objectField("selectedTab");
    try s.write(p.selected_tab);
    try s.objectField("tabs");
    try s.beginArray();
    for (p.tabs.items) |t| try writeUrl(gpa, s, t);
    try s.endArray();
    try s.objectField("viewMode");
    try s.write(@tagName(p.view_mode));
    try s.endObject();
}

fn writeTree(gpa: Allocator, s: *Stringify, t: *const PaneTree) !void {
    try s.beginObject();
    switch (t.*) {
        .leaf => |*p| {
            try s.objectField("pane");
            try writePane(gpa, s, p);
        },
        .split => |sp| {
            try s.objectField("axis");
            try s.write(sp.axis.jsonName());
            try s.objectField("children");
            try s.beginArray();
            for (sp.children) |*c| try writeTree(gpa, s, c);
            try s.endArray();
        },
    }
    try s.endObject();
}

/// The state as JSON text. Caller frees.
pub fn encode(gpa: Allocator, state: *const PersistedState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var s: Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
    try s.beginObject();
    try s.objectField("favorites");
    try writeEntries(gpa, &s, state.favorites.items);
    try s.objectField("layout");
    try writeTree(gpa, &s, &state.layout);
    try s.objectField("pinned");
    try writeEntries(gpa, &s, state.pinned.items);
    try s.objectField("showHidden");
    try s.write(state.show_hidden);
    try s.objectField("sidebarVisible");
    try s.write(state.sidebar_visible);
    try s.endObject();
    return out.toOwnedSlice();
}

// ---- decode ----

fn field(obj: Value, key: []const u8) ?Value {
    return obj.object.get(key);
}

fn asString(v: Value) DecodeError![]const u8 {
    return if (v == .string) v.string else error.InvalidState;
}

fn decodeEntry(gpa: Allocator, io: std.Io, v: Value) DecodeError!SidebarEntry {
    if (v != .object) return error.InvalidState;
    const url = try asString(field(v, "url") orelse return error.InvalidState);
    const path = try model.pathFromUrl(gpa, url);
    defer gpa.free(path);
    var title: ?[]const u8 = null;
    if (field(v, "title")) |t| switch (t) {
        .null => {},
        .string => |s| title = s,
        else => return error.InvalidState,
    };
    const id = if (field(v, "id")) |i| model.Uuid.parse(try asString(i)) orelse model.Uuid.random(io) else model.Uuid.random(io);
    return SidebarEntry.initWithId(gpa, id, path, title);
}

fn decodeEntries(gpa: Allocator, io: std.Io, v: Value) DecodeError!model.EntryList {
    if (v != .array) return error.InvalidState;
    var out: model.EntryList = .empty;
    errdefer model.deinitEntries(gpa, &out);
    for (v.array.items) |item| {
        var e = try decodeEntry(gpa, io, item);
        errdefer e.deinit(gpa);
        try out.append(gpa, e);
    }
    return out;
}

fn decodePane(gpa: Allocator, v: Value) DecodeError!PersistedPane {
    if (v != .object) return error.InvalidState;
    const tabs = field(v, "tabs") orelse return error.InvalidState;
    if (tabs != .array) return error.InvalidState;
    var p: PersistedPane = .{};
    errdefer p.deinit(gpa);
    for (tabs.array.items) |t| {
        const path = try model.pathFromUrl(gpa, try asString(t));
        errdefer gpa.free(path);
        try p.tabs.append(gpa, path);
    }
    if (field(v, "selectedTab")) |st| {
        if (st != .integer) return error.InvalidState;
        const n: usize = if (st.integer < 0) 0 else @intCast(st.integer);
        p.selected_tab = if (p.tabs.items.len > 0) @min(n, p.tabs.items.len - 1) else 0;
    }
    if (field(v, "viewMode")) |vm| p.view_mode = model.ViewMode.fromName(try asString(vm)) orelse .list;
    return p;
}

fn decodeTree(gpa: Allocator, v: Value) DecodeError!PaneTree {
    if (v != .object) return error.InvalidState;
    if (field(v, "pane")) |p| return .{ .leaf = try decodePane(gpa, p) };
    const axis = layout_tree.SplitAxis.fromJsonName(try asString(field(v, "axis") orelse return error.InvalidState)) orelse return error.InvalidState;
    const children = field(v, "children") orelse return error.InvalidState;
    if (children != .array) return error.InvalidState;
    const kids = try gpa.alloc(PaneTree, children.array.items.len);
    var done: usize = 0;
    errdefer {
        for (kids[0..done]) |*k| k.deinit(gpa);
        gpa.free(kids);
    }
    while (done < kids.len) : (done += 1) kids[done] = try decodeTree(gpa, children.array.items[done]);
    return PaneTree.splitOf(axis, kids);
}

/// A non-empty normalized layout from the `layout` key, or null if absent/invalid/empty.
fn decodeLayout(gpa: Allocator, v: Value) Allocator.Error!?PaneTree {
    var tree = decodeTree(gpa, v) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidState => return null,
    };
    defer tree.deinit(gpa);
    return tree.normalized(gpa);
}

fn decodeLegacy(gpa: Allocator, root: Value) DecodeError!?PaneTree {
    const panes = field(root, "panes") orelse return null;
    if (panes != .array) return error.InvalidState;
    if (panes.array.items.len == 0) return null;
    var list: std.ArrayList(PersistedPane) = .empty;
    defer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }
    for (panes.array.items) |item| {
        var p = try decodePane(gpa, item);
        errdefer p.deinit(gpa);
        try list.append(gpa, p);
    }
    var vertical = false;
    if (field(root, "splitVertical")) |sv| {
        if (sv != .bool) return error.InvalidState;
        vertical = sv.bool;
    }
    return PersistedState.flatLayout(gpa, list.items, vertical);
}

fn decodeBool(root: Value, key: []const u8, default: bool) DecodeError!bool {
    const v = field(root, key) orelse return default;
    return if (v == .bool) v.bool else error.InvalidState;
}

/// Parses `bytes`. Errors (other than OutOfMemory) mean "corrupt": the caller falls back to defaults.
pub fn decode(gpa: Allocator, io: std.Io, home: []const u8, bytes: []const u8) DecodeError!PersistedState {
    var parsed = std.json.parseFromSlice(Value, gpa, bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidState;

    var d = try PersistedState.defaults(gpa, io, home);
    defer d.deinit(gpa);

    var fav: model.EntryList = if (field(root, "favorites")) |v| try decodeEntries(gpa, io, v) else .empty;
    errdefer model.deinitEntries(gpa, &fav);
    if (field(root, "favorites") == null) {
        for (d.favorites.items) |*e| {
            var c = try e.clone(gpa);
            errdefer c.deinit(gpa);
            try fav.append(gpa, c);
        }
    }
    var pin: model.EntryList = if (field(root, "pinned")) |v| try decodeEntries(gpa, io, v) else .empty;
    errdefer model.deinitEntries(gpa, &pin);

    var layout: ?PaneTree = null;
    if (field(root, "layout")) |lv| layout = try decodeLayout(gpa, lv);
    if (layout == null) layout = try decodeLegacy(gpa, root);
    errdefer if (layout) |*l| l.deinit(gpa);
    if (layout == null) layout = try d.layout.clone(gpa);

    return .{
        .favorites = fav,
        .pinned = pin,
        .layout = layout.?,
        .show_hidden = try decodeBool(root, "showHidden", d.show_hidden),
        .sidebar_visible = try decodeBool(root, "sidebarVisible", d.sidebar_visible),
    };
}
