//! Helpers for the UI tests: a fresh temp folder tree (under the testing tmp dir, removed
//! afterwards; the only place a test ever reads) and a Tester over a model.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_view = @import("../app.zig");

const testing = std.testing;

pub const Fixture = struct {
    tmp: testing.TmpDir,
    /// The real absolute path of the temp folder (no /var -> /private/var surprises).
    root: []u8,

    pub fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const real = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(real);
        return .{ .tmp = tmp, .root = try testing.allocator.dupe(u8, real) };
    }

    pub fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup(); // own temp scaffolding only
    }

    /// A file of `size` bytes at `rel` (folders made as needed).
    pub fn file(self: *Fixture, rel: []const u8, size: usize) !void {
        if (std.fs.path.dirname(rel)) |d| try self.tmp.dir.createDirPath(testing.io, d);
        const data = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(data);
        @memset(data, 'x');
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = rel, .data = data });
    }

    pub fn dir(self: *Fixture, rel: []const u8) !void {
        try self.tmp.dir.createDirPath(testing.io, rel);
    }

    /// `rel` under the temp folder. Free with `testing.allocator`.
    pub fn sub(self: *const Fixture, rel: []const u8) ![]u8 {
        return std.fs.path.join(testing.allocator, &.{ self.root, rel });
    }
};

/// A window-less view of `m`, 900x560 points.
pub fn open(t: *ui.Tester, m: *app_view.State) !void {
    try t.init(testing.allocator, .init(m, app_view.view), .{ .width = 900, .height = 560 });
    t.settle(0.3);
}

/// The vertical center of text `s` in the last frame.
pub fn textY(t: *ui.Tester, s: []const u8) !f32 {
    const r = t.findText(s) orelse return error.TextNotFound;
    return r.y + r.h / 2;
}

/// Clicks the icon `symbol` (icon-only buttons have no text to click).
pub fn clickIcon(t: *ui.Tester, symbol: []const u8) !void {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol)) {
            t.click(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2);
            return;
        },
        else => {},
    };
    return error.IconNotFound;
}

pub fn hasIcon(t: *ui.Tester, symbol: []const u8) bool {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (std.mem.eql(u8, ic.name, symbol)) return true,
        else => {},
    };
    return false;
}

/// Clicks the middle of text `s` holding cmd and/or shift.
pub fn clickTextWith(t: *ui.Tester, s: []const u8, mods: struct { cmd: bool = false, shift: bool = false }) !void {
    const r = t.findText(s) orelse return error.TextNotFound;
    t.setMods(.{ .cmd = mods.cmd, .shift = mods.shift });
    t.click(r.x + r.w / 2, r.y + r.h / 2);
    t.setMods(.{});
}
