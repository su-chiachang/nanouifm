# nanofm (Zig)

A native macOS file manager written in Zig on [nanoui](https://github.com/justrach/nanoui), ported from the Swift
(SwiftUI + AppKit) version. Native UI drawn on the GPU by nanoui: no webview, no HTML.

## Features

- List view (sortable columns, folders expand in place) and Miller column view with a preview column, per pane.
- Tabs and split panes with draggable dividers, 12 layout presets, focus handling, per-tab history.
- Sidebar with Favorites, Pinned and live Locations (mounted volumes, eject); drag to reorder or add folders.
- Command palette (Cmd+K): fuzzy command search plus a background file index.
- File operations with undo/redo (delete always means Move to Trash), inline rename, copy/paste, duplicate.
- Context menus, native menu bar generated from one command registry, keyboard navigation, type-to-select.
- Live refresh of every visible folder (kqueue-backed, debounced, nothing polls).
- Inspector (Alt+Cmd+I) with details and image resolution, Quick Look (Space / Cmd+Y), Share.
- Layout, tabs, favorites and preferences persist across launches.

## Requirements

- macOS 14 or later
- Zig 0.17.1 (`brew install zig`), plus Xcode or the Command Line Tools

nanoui is a pinned dependency (v0.14.6, fetched by `zig build`). The only runtime dependencies are system frameworks.

## Build, test, bundle

```sh
zig build                       # compile
zig build test                  # UI tests: views rendered offscreen with ui.Tester (no window opens)
zig build test-core             # the core library tests (-Dcore=<module> for one module)
scripts/bundle.sh               # build/nanofm.app (ad-hoc signed) and build/release/nanofm-<version>-macos.zip
```

`zig build run` opens the app's window. Snapshots without a window:
`NANOFM_SNAPSHOT_PNG=/tmp/shot.png zig build test` writes PNGs of the snapshot tests.

Distribution signing: `SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=<profile> scripts/bundle.sh`
(`xcrun notarytool store-credentials <profile>` once). `OPTIMIZE` picks the Zig optimize mode (default `ReleaseSafe`).

State is stored in `~/Library/Application Support/nanofm`; set `NANOFM_STATE_DIR` to use another folder.

## Layout

```text
src/core/    file listing, operations with undo, fuzzy match, search index, watcher, state store, layouts (no UI)
src/ui/      model, panes, tabs, list and column views, sidebar, palette, menus, inspector, tests
src/app.zig  root view; src/main.zig the real-system wiring (HOME, state dir, menu bar, hooks)
scripts/     bundle.sh
Resources/   app icon
```

Everything that touches the system (clipboard, opener, Reveal, Quick Look, thumbnails, share, volumes, file watching,
state store) goes through injectable hooks, so tests run on temporary directories only and never touch your files.
Files stay at or under 600 lines (nanoui's rule). See `AGENTS.md` for the commands and conventions.

## Known gaps

- **Not verified in a running app** (compiled and wired, but tests cannot show a window): the real Quick Look panel,
  thumbnails, the share sheet, native menu-bar key handling, volume mount notifications, and the real file watcher.
- Dragging items out of nanofm to Finder is not possible: nanoui's drag source writes plain text only. Dragging between
  panes and dropping files in from Finder work.
- Folder listing runs on the main thread; very large folders can stall a frame.
- Row icons are generic symbols, not per-file Finder icons.
- No Open With submenu (default app only), no window growth when applying a layout preset.
- Cross-volume moves fail with an error instead of copy-then-delete (nothing is ever unlinked); drops fall back to copy.
- Name sorting does not ignore diacritics.
