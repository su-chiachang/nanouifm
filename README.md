# nanofm (Zig)

A native macOS file manager written in Zig on [nanoui](https://github.com/justrach/nanoui), ported from the Swift
(SwiftUI + AppKit) version. Native UI drawn on the GPU by nanoui: no webview, no HTML.

## Features

- List view (sortable columns, folders expand in place) and Miller column view with a preview column, per pane.
- Tabs and split panes with draggable dividers, 12 layout presets, focus handling, per-tab history.
- Sidebar with Favorites, Pinned and live Locations (mounted volumes, eject); drag to reorder or add folders.
- Command palette (Cmd+K): fuzzy command search plus a background file index.
- File operations with undo/redo (delete always means Move to Trash), inline rename, copy/paste, duplicate.
- Context menus (with Open With rows), native menu bar generated from one command registry, keyboard navigation, type-to-select.
- Live refresh of every visible folder (kqueue-backed, debounced, nothing polls); folders are listed off the main thread.
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

## Verifying without a window

The real system providers (NSWorkspace icons, QLThumbnailGenerator thumbnails, the worker-thread listing runner) answer
through `objc.dispatchMain`, i.e. only while the main run loop is pumped. nanoui's hidden snapshot run pumps it during
`--nanoui-wait=SECONDS` (before the script) and during the script step `live:SECONDS`, but NOT during `wait:SECONDS`,
which is simulated time: anything the script makes the view ask for (the inspector's thumbnail and 128 px icon after a
click) stays at the generic symbol if the snapshot is taken after `wait:`. Use `live:`:

```sh
sd=$(mktemp -d)   # never the real state folder
NANOFM_STATE_DIR=$sd zig-out/bin/nanofm --nanoui-snapshot=/tmp/inspector.png \
  --nanoui-script='click:<a file name on the Desktop>;at:582,53;live:6' --nanoui-wait=3
```

`at:582,53` is the inspector toggle of the focused pane at the default 1000x640 size. With `live:6` the QuickLook
thumbnail (a picture's own pixels) or, for files without one, Finder's icon appears; with `wait:25` in its place the
panel keeps the document symbol however long it is. The state folder must be a temp one and the app is never started
without `--nanoui-snapshot` (no window appears; nothing is written outside `$sd`).

## Known gaps

- **Not verified in a running app** (compiled and wired, but tests cannot show a window): the real Quick Look panel,
  the share sheet, the real window resize (`system_window.zig`) and the NSWorkspace app list and launch
  (`system_open_with.zig`), native menu-bar key handling, volume mount notifications, the real file watcher, and the
  worker-thread listing runner (`system_listing.zig`; the held and immediate runners are tested).
- Dragging items out of nanofm to Finder is not possible: nanoui's drag source writes plain text only. Dragging between
  panes and dropping files in from Finder work.
- Folder reads run on worker threads (navigation, back/forward, reload, columns, folders opened in place, new tabs and
  panes); the tab shows its old folder with "Loading…" until the new one lands. Still read on the main thread: the start
  folder at launch (before the first frame), and the refresh right after a file operation (the operations themselves
  already run on the main thread). Sorting and filtering a landed listing (in memory) still happens on the main thread.
  Two Back presses before the first one lands count as one.
- Row, crumb and inspector icons are Finder's per-type icons (by extension; applications, the disk root and the home
  folder by path), asked for once per key. Checked with the bundled app's hidden `--nanoui-snapshot` run (real
  NSWorkspace icons appeared for PNG, PDF, source and audio files and for folders). Not shown: folders with a custom icon (they get the plain folder icon),
  executables without an extension (generic document), the sidebar and the tab strip (SF symbols).
- Open With is a list of flat rows ("Open With Preview (default)", ...; at most 8 apps, single files only), not a
  submenu: nanoui's menus have none. Opening reports no success or failure of the launched app (NSWorkspace's
  completion handler is not used).
- The window grows (within the screen) when a split or a layout preset needs room (320 x 200 per pane, equal shares),
  but unlike the Swift app a layout that cannot fit even after growing is still applied (dividers stop at 160 x 120).
- Cross-volume moves fail with an error instead of copy-then-delete (nothing is ever unlinked); drops fall back to copy.
- Name sorting does not ignore diacritics.
