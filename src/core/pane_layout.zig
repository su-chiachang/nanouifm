//! Pane layout: the layout tree, the 12 presets and the window-growth math
//! (port of PaneLayout.swift, LayoutPreset.swift, DockGrowth.swift). Pure logic, no UI.
//! Split over layout_tree.zig / layout_preset.zig / dock_growth.zig to stay under 600 lines each.
pub const layout_tree = @import("layout_tree.zig");
pub const layout_preset = @import("layout_preset.zig");
pub const dock_growth = @import("dock_growth.zig");

pub const SplitAxis = layout_tree.SplitAxis;
pub const DockSide = layout_tree.DockSide;
pub const LayoutTree = layout_tree.LayoutTree;
pub const sameShape = layout_tree.sameShape;
pub const LayoutPreset = layout_preset.LayoutPreset;
pub const PresetPlan = layout_preset.PresetPlan;
pub const DockGrowth = dock_growth;

test {
    _ = layout_tree;
    _ = layout_preset;
    _ = dock_growth;
}
