//! The native menu bar, installed by main.zig only (tests never build it: `menu_template.zig` is
//! what they check, as a pure function). `install` builds the template once (`App.setMenu`) and
//! keeps the items; `sync` then brings each one's title (Undo and Redo name what they undo), enabled
//! state and check mark up to date in place (`Item.setLabel` / `setEnabled` / `setChecked`), only
//! where it changed. The model calls it after the passes that ran actions, and each menu calls it
//! as it is about to show (`on_open`), so the structure never needs rebuilding: it never changes.
const std = @import("std");
const nanoui = @import("nanoui");
const Allocator = std.mem.Allocator;
const Model = @import("model.zig").Model;
const commands = @import("commands.zig");
const template = @import("menu_template.zig");
const menu_link = @import("menu_link.zig");

pub const Bar = struct {
    gpa: Allocator,
    m: *Model,
    host: template.Host,
    items: [menu_link.count]?*nanoui.menu.Item = @splat(null),
    shown: [menu_link.count]?template.ItemState = @splat(null),
    titles: [menu_link.count]u64 = @splat(0),

    /// Builds the menu bar from the model and the registry and makes it the app's.
    pub fn install(gpa: Allocator, app: *nanoui.App, m: *Model) !*Bar {
        const self = try gpa.create(Bar);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .m = m, .host = .{ .m = m } };
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        try app.setMenu(try template.build(arena.allocator(), m, &self.host));
        for (&commands.all) |*c| self.items[@backingInt(c.id)] = app.menuItem(@tagName(c.id));
        m.menu = .{ .installed = true, .sync = syncThunk, .ctx = self };
        self.sync();
        return self;
    }

    /// Detaches the model (the menu bar itself belongs to the app until it is destroyed).
    pub fn destroy(self: *Bar) void {
        self.m.menu = .{};
        self.gpa.destroy(self);
    }

    pub fn sync(self: *Bar) void {
        var tbuf: [128]u8 = undefined;
        for (&commands.all) |*c| {
            const i = @backingInt(c.id);
            const item = self.items[i] orelse continue;
            const st = template.stateOf(self.m, c);
            self.m.menu.enabled.setValue(i, st.enabled);
            const old = self.shown[i];
            if (old == null or old.?.enabled != st.enabled) item.setEnabled(st.enabled);
            // (always: nanoui flips a checkbox or radio when it is clicked, whatever the command did)
            if (c.checked != null) item.setChecked(st.checked);
            self.shown[i] = st;
            if (c.dynamic_title != null) {
                const title = commands.titleOf(self.m, c, &tbuf);
                const h = std.hash.Wyhash.hash(0, title);
                if (h != self.titles[i]) {
                    item.setLabel(title);
                    self.titles[i] = h;
                }
            }
        }
    }
};

fn syncThunk(ctx: *anyopaque) void {
    const self: *Bar = @ptrCast(@alignCast(ctx));
    self.sync();
}
