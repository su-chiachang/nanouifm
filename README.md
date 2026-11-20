# nanofm (Zig)

A native macOS file manager written in Zig on [nanoui](https://github.com/justrach/nanoui), ported from the Swift
(SwiftUI + AppKit) version. The UI is drawn on the GPU by nanoui: no webview, no HTML.

## Features

- **Browsing:** list view (sortable columns, folders expand in place) and Miller column view with a preview column, per
  pane; keyboard navigation and type-to-select.
- **Panes and tabs:** tabs with per-tab history, split panes with draggable dividers, 12 layout presets (the window
  grows to fit), focus handling.
- **Sidebar:** Favorites, Pinned and live Locations (mounted volumes, eject); drag to reorder or add folders.
- **Command palette (Cmd+K):** fuzzy command search plus a background file index.
- **File operations:** undo/redo, inline rename, copy/paste, duplicate, drag and drop between panes and in from
  Finder. Delete always means Move to Trash; nothing is ever unlinked.
- **Menus:** context menus (with Open With rows) and a native menu bar, both generated from one command registry.
- **Live refresh:** every visible folder is watched (kqueue-backed, debounced, nothing polls) and listed off the main
  thread.
- **Inspector and previews:** Alt+Cmd+I inspector with details and image resolution, Finder icons and QuickLook
  thumbnails, Quick Look panel (Space / Cmd+Y), Share.
- **Persistence:** layout, tabs, favorites and preferences survive relaunch.

## Requirements

- macOS 14 or later
- Zig 0.17.1 (`brew install zig`) and Xcode or the Command Line Tools

nanoui is a pinned dependency (v0.14.6, fetched by `zig build`). The only runtime dependencies are system frameworks.

## Build, test, bundle

```sh
zig build                       # compile
zig build run                   # open the app's window
zig build test                  # UI tests: views rendered offscreen with ui.Tester (no window opens)
zig build test-core             # core library tests (-Dcore=<module> for one module)
scripts/bundle.sh               # build/nanofm.app (ad-hoc signed) and build/release/nanofm-<version>-macos.zip
```

- `zig build test -Dtest-filter=text` runs only the tests whose name contains `text`.
- `NANOFM_SNAPSHOT_PNG=/tmp/shot.png zig build test` also writes PNGs of the snapshot tests.
- Build steps are cached: a step that did not run prints no test count. To force a run, change a source file.
- Distribution signing: `SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=<profile>
  scripts/bundle.sh` (run `xcrun notarytool store-credentials <profile>` once). `OPTIMIZE` picks the Zig optimize mode
  (default `ReleaseSafe`).
- State lives in `~/Library/Application Support/nanofm`; set `NANOFM_STATE_DIR` to use another folder.

## Project layout

```text
src/core/    file listing, operations with undo, fuzzy match, search index, watcher, state store, layouts (no UI)
src/ui/      model, panes, tabs, list and column views, sidebar, palette, menus, inspector, tests
src/app.zig  root view; src/main.zig the real-system wiring (HOME, state dir, menu bar, hooks)
scripts/     bundle.sh
Resources/   app icon
docs/        VERIFYING.md: checking the real system parts without a window
```

Everything that touches the system (clipboard, opener, Reveal, Quick Look, thumbnails, icons, share, volumes, file
watching, window frame, Open With, state store) goes through injectable hooks, so tests run on temporary directories only
and never touch your files. Files stay at or under 600 lines (nanoui's rule). `AGENTS.md` lists the commands, the
conventions and every source file.

## Status

Tests: 358 of 373 UI tests and all 99 core tests pass. The 15 skipped UI tests only write snapshot PNGs and run when
`NANOFM_SNAPSHOT_PNG` is set.

**Checked in the real, bundled app** (hidden `--nanoui-snapshot` runs with a temp state folder, plus one short visible
launch; no input was sent to the OS): Finder icons and QuickLook thumbnails, live refresh when files change from outside
(and the worker-thread listing behind it), saving and restoring state across launches, volume mount and unmount, the
Quick Look panel opening and following the selection, the menu bar's key equivalents (Cmd+T, W, D, Shift+Cmd+D,
Ctrl+Cmd+S, Cmd+K, Cmd+Z, ...), window growth on split, and the real Open With app list. The app stayed up for 10 s and
idled at 0% CPU. How each was checked, and what was observed, is in [docs/VERIFYING.md](docs/VERIFYING.md).

**Not checked** (compiled and wired, but they need a visible active window or real input): the Share popover, launching
an app from Open With, Cmd+Backspace and arrow keys from a real keyboard, and Quick Look's arrow keys, Escape and close
button while its panel is key.

## Known limitations

- **Dragging out to Finder is not possible.** nanoui's drag source writes plain text only. Dragging between panes and
  dropping files in from Finder work.
- **Cross-volume moves fail with an error** instead of copy-then-delete (nothing is ever unlinked); drops fall back to a
  copy.
- **Reads on the main thread:** the start folder at launch (before the first frame), the refresh right after a file
  operation, and sorting/filtering an already loaded listing. Everything else is read on worker threads, and a tab keeps
  showing its old folder with "Loading…" until the new one lands. Two Back presses before the first lands count as one.
- **Icons:** Finder's per-type icons are used for rows, crumbs and the inspector, but folders with a custom icon get the
  plain folder icon, extensionless executables a generic document, and the sidebar and tab strip use SF Symbols.
- **Open With** is a flat list of rows (default app first, at most 8, single files only), not a submenu, because nanoui's
  menus have none. Launching an app reports no success or failure.
- **Window growth** aims for 320 x 200 per pane within the screen; unlike the Swift app, a layout that still cannot fit
  is applied anyway (dividers stop at 160 x 120).
- **Return renames** (as in the Swift app); open with Cmd+O or Cmd+Down. Cmd+Backspace is handled by the view, not the
  menu, so a Delete-key mismatch in AppKit cannot disable Move to Trash.
- Name sorting does not ignore diacritics.
