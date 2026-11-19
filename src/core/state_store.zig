//! StateStore: reads and writes `<directory>/state.json` (port of StateStore.swift).
//! The directory is injected (the app passes ~/Library/Application Support/nanofm; tests a temp dir).
//! `load` never fails on a missing/corrupt file (it returns `defaults`); `save` is atomic
//! (temp file in the same directory, then rename over state.json).
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const model = @import("state_model.zig");
pub const json = @import("state_json.zig");

pub const Uuid = model.Uuid;
pub const SidebarEntry = model.SidebarEntry;
pub const PersistedPane = model.PersistedPane;
pub const PersistedState = model.PersistedState;
pub const ViewMode = model.ViewMode;
pub const PaneTree = model.PaneTree;
pub const EntryList = model.EntryList;
pub const urlFromPath = model.urlFromPath;
pub const pathFromUrl = model.pathFromUrl;

pub const StateStore = struct {
    gpa: Allocator,
    io: std.Io,
    /// Owned copies.
    directory: []u8,
    home: []u8,
    file_path: []u8,
    tmp_path: []u8,

    /// `directory` is absolute or relative to the cwd; it is created on the first save.
    /// `home` is the user's home folder, used for `PersistedState.defaults`.
    pub fn init(gpa: Allocator, io: std.Io, directory: []const u8, home: []const u8) Allocator.Error!StateStore {
        const dir = try gpa.dupe(u8, directory);
        errdefer gpa.free(dir);
        const h = try gpa.dupe(u8, home);
        errdefer gpa.free(h);
        const file = try std.fs.path.join(gpa, &.{ directory, "state.json" });
        errdefer gpa.free(file);
        const tmp = try std.fs.path.join(gpa, &.{ directory, ".state.json.tmp" });
        return .{ .gpa = gpa, .io = io, .directory = dir, .home = h, .file_path = file, .tmp_path = tmp };
    }

    pub fn deinit(self: *StateStore) void {
        self.gpa.free(self.directory);
        self.gpa.free(self.home);
        self.gpa.free(self.file_path);
        self.gpa.free(self.tmp_path);
        self.* = undefined;
    }

    /// Missing or corrupt file gives `defaults()`; the only possible error is out-of-memory.
    /// The result is owned by the caller (`deinit(gpa)`).
    pub fn load(self: *const StateStore) Allocator.Error!PersistedState {
        const cwd = std.Io.Dir.cwd();
        const bytes = cwd.readFileAlloc(self.io, self.file_path, self.gpa, .limited(16 << 20)) catch
            return PersistedState.defaults(self.gpa, self.io, self.home);
        defer self.gpa.free(bytes);
        return json.decode(self.gpa, self.io, self.home, bytes) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidState => PersistedState.defaults(self.gpa, self.io, self.home),
        };
    }

    /// Atomic write of state.json: a temporary file beside it is renamed over it, so a crash
    /// leaves the old file or the new one, never half of one.
    pub fn save(self: *const StateStore, state: *const PersistedState) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.directory);
        const bytes = try json.encode(self.gpa, state);
        defer self.gpa.free(bytes);
        try cwd.writeFile(self.io, .{ .sub_path = self.tmp_path, .data = bytes });
        cwd.rename(self.tmp_path, cwd, self.file_path, self.io) catch |e| {
            cwd.deleteFile(self.io, self.tmp_path) catch {};
            return e;
        };
    }
};

// ---- tests (port of StateStoreTests; temp dirs only) ----

const testing = std.testing;
const test_home = "/tmp/nanofm-test-home/user";

const Scratch = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    len: usize = 0,

    fn init() !Scratch {
        var s: Scratch = .{ .tmp = testing.tmpDir(.{}) };
        s.len = try s.tmp.dir.realPathFile(testing.io, ".", &s.buf);
        return s;
    }
    fn cleanup(s: *Scratch) void {
        s.tmp.cleanup();
    }
    fn path(s: *const Scratch) []const u8 {
        return s.buf[0..s.len];
    }
    fn sub(s: *const Scratch, gpa: Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(gpa, &.{ s.path(), name });
    }
    fn write(s: *Scratch, name: []const u8, data: []const u8) !void {
        try s.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }
};

fn onePane(gpa: Allocator, tabs: []const []const u8, sel: usize, mode: ViewMode) !PaneTree {
    return .{ .leaf = try PersistedPane.init(gpa, tabs, sel, mode) };
}

fn expectDefaultPanes(gpa: Allocator, s: *const PersistedState) !void {
    var d = try PersistedState.defaults(gpa, testing.io, test_home);
    defer d.deinit(gpa);
    try testing.expect(s.layout.eql(&d.layout));
    try testing.expectEqual(@as(usize, 4), s.favorites.items.len);
}

fn lastComponents(gpa: Allocator, s: *const PersistedState) ![]const u8 {
    const panes = try s.panes(gpa);
    defer gpa.free(panes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (panes, 0..) |p, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, std.fs.path.basename(p.tabs.items[0]));
    }
    return out.toOwnedSlice(gpa);
}

test "defaults" {
    const gpa = testing.allocator;
    var d = try PersistedState.defaults(gpa, testing.io, test_home);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), d.favorites.items.len);
    const want = [_][]const u8{ "Desktop", "Documents", "Downloads", "user" };
    for (d.favorites.items, want) |e, w| try testing.expectEqualStrings(w, std.fs.path.basename(e.path));
    try testing.expectEqualStrings(test_home ++ "/Desktop", d.favorites.items[0].path);
    try testing.expectEqual(@as(usize, 0), d.pinned.items.len);
    const names = try lastComponents(gpa, &d);
    defer gpa.free(names);
    try testing.expectEqualStrings("Desktop,Documents,Downloads,user", names);
    const panes = try d.panes(gpa);
    defer gpa.free(panes);
    try testing.expectEqual(@as(usize, 4), panes.len);
    try testing.expectEqual(ViewMode.list, panes[0].view_mode);
    // 2x2: stacked rows of two side-by-side cells.
    try testing.expect(d.layout == .split and d.layout.split.axis == .stacked and d.layout.split.children.len == 2);
    for (d.layout.split.children) |row| {
        try testing.expect(row == .split and row.split.axis == .side_by_side and row.split.children.len == 2);
    }
    try testing.expect(!d.show_hidden);
    try testing.expect(d.sidebar_visible);
}

test "round trip, overwrite, no temp droppings" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.cleanup();
    const dir = try scratch.sub(gpa, "nested/nanofm"); // created on save
    defer gpa.free(dir);
    var store = try StateStore.init(gpa, testing.io, dir, test_home);
    defer store.deinit();

    var stack = try PaneTree.splitFrom(gpa, .stacked, &.{
        try onePane(gpa, &.{"/tmp/c"}, 0, .list),
        try onePane(gpa, &.{"/tmp/d"}, 0, .list),
    });
    _ = &stack;
    var layout = try PaneTree.splitFrom(gpa, .side_by_side, &.{
        try onePane(gpa, &.{ "/tmp/a", "/tmp/b with space" }, 1, .column),
        stack,
    });
    var state: PersistedState = .{ .layout = layout, .show_hidden = true, .sidebar_visible = false };
    _ = &layout;
    defer state.deinit(gpa);
    try state.favorites.append(gpa, try SidebarEntry.init(gpa, testing.io, "/tmp/fav", "Fav"));
    try state.pinned.append(gpa, try SidebarEntry.init(gpa, testing.io, "/tmp/pin", null));

    try store.save(&state);
    var loaded = try store.load();
    defer loaded.deinit(gpa);
    try testing.expect(loaded.eql(&state));

    // a second store over the same directory sees it too
    var store2 = try StateStore.init(gpa, testing.io, dir, test_home);
    defer store2.deinit();
    var loaded2 = try store2.load();
    defer loaded2.deinit(gpa);
    try testing.expect(loaded2.eql(&state));

    // overwrite
    state.show_hidden = false;
    state.layout.split.children[0].leaf.selected_tab = 0;
    try store.save(&state);
    var again = try store.load();
    defer again.deinit(gpa);
    try testing.expect(again.eql(&state));
    try testing.expect(!again.show_hidden);

    // only state.json is left in the directory
    var d = try std.Io.Dir.cwd().openDir(testing.io, dir, .{ .iterate = true });
    defer d.close(testing.io);
    var it = d.iterate();
    var count: usize = 0;
    while (try it.next(testing.io)) |e| {
        try testing.expectEqualStrings("state.json", e.name);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "JSON shape matches the Swift Codable layout" {
    const gpa = testing.allocator;
    var state = try PersistedState.defaults(gpa, testing.io, test_home);
    defer state.deinit(gpa);
    const text = try json.encode(gpa, &state);
    defer gpa.free(text);
    for ([_][]const u8{
        "\"axis\": \"sideBySide\"",           "\"axis\": \"stacked\"",    "\"pane\":",
        "\"url\": \"file:///tmp/nanofm-test-home/user/Desktop\"", "\"showHidden\": false", "\"sidebarVisible\": true",
        "\"viewMode\": \"list\"",             "\"selectedTab\": 0",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, text, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "splitVertical") == null);
}

test "legacy panes and splitVertical load flat" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.cleanup();
    var store = try StateStore.init(gpa, testing.io, scratch.path(), test_home);
    defer store.deinit();
    for ([_]bool{ true, false }) |vertical| {
        const text = try std.fmt.allocPrint(gpa,
            \\{{"showHidden": true, "splitVertical": {s},
            \\ "panes": [{{"tabs": ["file:///tmp/a"], "selectedTab": 0, "viewMode": "list"}},
            \\           {{"tabs": ["file:///tmp/b"], "selectedTab": 0, "viewMode": "column"}},
            \\           {{"tabs": ["file:///tmp/c"], "selectedTab": 0, "viewMode": "list"}}]}}
        , .{if (vertical) "true" else "false"});
        defer gpa.free(text);
        try scratch.write("state.json", text);
        var loaded = try store.load();
        defer loaded.deinit(gpa);
        try testing.expect(loaded.layout == .split);
        try testing.expectEqual(if (vertical) json_axis.stacked else json_axis.side_by_side, loaded.layout.split.axis);
        try testing.expectEqual(@as(usize, 3), loaded.layout.split.children.len);
        const names = try lastComponents(gpa, &loaded);
        defer gpa.free(names);
        try testing.expectEqualStrings("a,b,c", names);
        try testing.expect(loaded.show_hidden);
    }
    // A single legacy pane becomes a lone leaf; the saved file only carries `layout`.
    try scratch.write("state.json", "{\"panes\": [{\"tabs\": [\"file:///tmp/a\"], \"selectedTab\": 0, \"viewMode\": \"list\"}]}");
    var single = try store.load();
    defer single.deinit(gpa);
    try testing.expect(single.layout == .leaf);
    try testing.expectEqualStrings("/tmp/a", single.layout.leaf.tabs.items[0]);
    try store.save(&single);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, store.file_path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"layout\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "splitVertical") == null);
}

const json_axis = @import("layout_tree.zig").SplitAxis;

test "missing file gives defaults" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.cleanup();
    const dir = try scratch.sub(gpa, "never-created");
    defer gpa.free(dir);
    var store = try StateStore.init(gpa, testing.io, dir, test_home);
    defer store.deinit();
    var loaded = try store.load();
    defer loaded.deinit(gpa);
    try expectDefaultPanes(gpa, &loaded);
    try testing.expectEqualStrings(test_home ++ "/Desktop", loaded.favorites.items[0].path);
    // loading never created the directory
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dir, .{}));
}

test "corrupt file falls back to defaults" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.cleanup();
    var store = try StateStore.init(gpa, testing.io, scratch.path(), test_home);
    defer store.deinit();
    const garbage = [_][]const u8{
        "not json at all",
        "{\"favorites\": 5}",
        "",
        "[1,2,3]",
        "{\"panes\": [{\"tabs\": 3}]}",
        "{\"showHidden\": \"yes\"}",
        &.{ 0xFF, 0x00, 0xFE },
    };
    for (garbage) |g| {
        try scratch.write("state.json", g);
        var loaded = try store.load();
        defer loaded.deinit(gpa);
        try expectDefaultPanes(gpa, &loaded);
        try testing.expect(!loaded.show_hidden);
    }
}

test "partial file uses defaults for missing fields" {
    const gpa = testing.allocator;
    var scratch = try Scratch.init();
    defer scratch.cleanup();
    var store = try StateStore.init(gpa, testing.io, scratch.path(), test_home);
    defer store.deinit();
    try scratch.write("state.json", "{\"showHidden\": true}");
    var loaded = try store.load();
    defer loaded.deinit(gpa);
    try testing.expect(loaded.show_hidden);
    try testing.expectEqual(@as(usize, 4), loaded.favorites.items.len);
    try testing.expect(loaded.sidebar_visible);
    try expectDefaultPanes(gpa, &loaded);
}

test "urls and uuids" {
    const gpa = testing.allocator;
    const url = try urlFromPath(gpa, "/Users/me/My Docs/caf\u{e9}");
    defer gpa.free(url);
    try testing.expectEqualStrings("file:///Users/me/My%20Docs/caf%C3%A9", url);
    const back = try pathFromUrl(gpa, url);
    defer gpa.free(back);
    try testing.expectEqualStrings("/Users/me/My Docs/caf\u{e9}", back);
    const dir = try pathFromUrl(gpa, "file:///Users/me/Desktop/");
    defer gpa.free(dir);
    try testing.expectEqualStrings("/Users/me/Desktop", dir);
    const root = try pathFromUrl(gpa, "file:///");
    defer gpa.free(root);
    try testing.expectEqualStrings("/", root);
    const plain = try pathFromUrl(gpa, "/tmp/plain%20name");
    defer gpa.free(plain);
    try testing.expectEqualStrings("/tmp/plain%20name", plain);

    const id = Uuid.random(testing.io);
    const text = id.format();
    try testing.expect(Uuid.parse(&text).?.eql(id));
    try testing.expectEqual(@as(u8, '-'), text[8]);
    try testing.expect(Uuid.parse("not-a-uuid") == null);
}

test {
    _ = @import("pane_layout.zig");
}
