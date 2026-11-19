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

- **Verified in the bundled app's hidden snapshot run** (`--nanoui-snapshot` with `live:SECONDS`, temp state folder):
  real file icons, real QuickLook thumbnails and 128 px icons in the inspector, the real file watcher refreshing a
  folder when a file is created from outside, the worker-thread listing runner doing that reload, saving state to
  `state.json` after opening a tab, and restoring the tabs on the next launch.
- **Launched once with a visible window** (user-approved, no input sent, temp state folder): the bundled app stayed up
  for 10 s with no error output, idled at 0.0% CPU (about 108 MB), and exited cleanly on SIGTERM.
- **Quick Look panel, verified in the hidden snapshot run** (temp state folder with a 6-byte `hello-ql.txt` and a 16x16
  `tiny.png`, temporary stderr diagnostics, since removed). Script (Space is not a menu accelerator, so `chord:space`
  reaches the view; `chord:cmd+k` and `chord:cmd+y` do NOT, the menu bar owns them, so the palette cannot be opened
  that way; `rclick:` does not open the in-view context menu either):
  `NANOFM_STATE_DIR=$sd zig-out/bin/nanofm --nanoui-snapshot=$sd/o.png '--nanoui-script=live:2;click:hello-ql.txt;chord:space;live:5;chord:down;live:3' --nanoui-wait=0`.
  Observed: the command ran with the hook installed and 1 path; the shared `QLPreviewPanel` was obtained; the data
  source and delegate were set; QL called `numberOfPreviewItems` and `previewItemAtIndex:0` (an NSURL); after
  `makeKeyAndOrderFront:` the panel was `isVisible` with `dataSource` set, 1 item, index 0, a current preview item, and
  `sharedPreviewPanelExists`. A read-only CoreGraphics window list (owner nanofm/QuickLook) during the run showed one
  on-screen window, `owner=nanofm layer=9 w=816 h=849` (the text preview). `chord:down` moved the selection to
  `tiny.png`: `sync` called the hook's `update` once with that path, QL asked for the item again, and the window became
  `w=370 h=223` (the image preview). No error output; the panel went away with the process. Not provable there: the hidden
  process is not the active app (`NSApp isActive` false, the panel is not key, `currentController` is nil, and
  `activateIgnoringOtherApps:` has no effect), so key handling (`previewPanel:handleEvent:` for arrows pressed while the
  panel is key), Escape / close button and whether QL keeps a directly set data source once the panel becomes key in a
  really active app still need a person.
- **Menu-bar key handling, window growth and Open With, verified in the hidden snapshot run** (temp state folder with
  `hello.txt`, `b.txt`, a 16x16 `tiny.png` and a one-pane `state.json`; temporary stderr diagnostics driven from a
  wrapper around the view in main.zig, since removed). The recipe: after the first frames, in-process, walk
  `[NSApp mainMenu]` (`numberOfItems`/`itemAtIndex:`/`keyEquivalent`/`keyEquivalentModifierMask`/`isEnabled`) and call
  `[[NSApp mainMenu] performKeyEquivalent:event]` with an NSEvent that is never posted to the OS. Build the event from
  `CGEventCreateKeyboardEvent` + `CGEventSetFlags` + `+[NSEvent eventWithCGEvent:]` (a CG-backed event with the
  characters AppKit really computes: Shift+Cmd+D has `charactersIgnoringModifiers` = "D"; the hand-built
  `keyEventWithType:...` with "D" does NOT match a menu key "d", the CG-backed one does) and log the BOOL and the model
  (panes, tabs, sidebar, palette, window frame) each frame. Observed, run as
  `NANOFM_STATE_DIR=$sd zig-out/bin/nanofm --nanoui-snapshot=$sd/o.png '--nanoui-script=live:10' --nanoui-wait=0`:
  - The menu returns YES and the effect lands on the next frame for Cmd+T (tabs 1 to 2), Cmd+W (2 to 1), Cmd+D (panes
    1 to 2), Shift+Cmd+D (2 to 3), Ctrl+Cmd+S (sidebar hidden, again shown), Shift+Cmd+. (hidden files), Cmd+1 / Cmd+2
    (list / column), Shift+Cmd+N ("untitled folder" created), Cmd+K (palette open, seen in the final PNG), and, once the
    rename field no longer has the keyboard, Cmd+Z (listing 4 items to 3) and Shift+Cmd+Z (3 to 4).
  - It returns NO, as designed, for the keys the view owns: Return, Cmd+Down, Ctrl+Tab, Space, Cmd+Backspace (no menu
    accelerator: `menu_link.ownsKey`), for Undo / Redo / Close Pane while their items are disabled, and for EVERY chord
    while a text field has the keyboard (rename field, palette): `ui.suspendMenuKeyEquivalents`; the view's dispatcher
    (`command_keys.zig`, covered by the offscreen tests, not driven here) is what takes them then, e.g. Cmd+Z during a
    rename or Cmd+K to close the palette. So Cmd+K in the real app opens the palette
    through the MENU path, which is why the view-level `chord:cmd+k` of a script never does: that matches menu_link's
    ownership design, there is no bug.
  - Window growth: with the screen's visible frame (1443 x 938 here) logged, splitting one pane with Cmd+D leaves the
    1000-wide window alone for 2 panes (they fit), grows it to 1174 wide for 3 (x unchanged), to 1443 for 4 with x pushed
    back to the screen's left edge (0), and stays at 1443 for 5 to 8 panes: the real `Window.frame` / `setFrame` hook
    grows only, within the screen, and the resize lands one frame after the split (it is dispatched to the next turn of
    the main loop). Height 640 never changed (one row). The snapshot's own Tester keeps its 1000 x 640 size, so the PNG
    does not show the larger window.
  - Open With, the real provider (`system_open_with.list`): for `hello.txt` and `b.txt` 12 apps, TextEdit (the default)
    first, then Numbers, Sublime Text, Pages, Instruments, Script Editor, Claude, Safari, Visual Studio Code, Xcode,
    Google Chrome, Notes; for `tiny.png` 7 apps, Preview first, ColorSync Utility, Google Chrome, Claude, Safari,
    QuickTime Player, Image Playground; no duplicates, names without ".app". The context menu rows path works too: the
    script verbs `rclick:` / `rat:` send a button-right click, not the SECONDARY click `row_input.zig` listens for, so
    the diagnostics called `c.secondaryDown()` on the view's context (what `Tester.secondaryClick` does) with the mouse
    on a row: the menu opened, the real provider was asked once (`open_with.State.lookups` 0 to 1) and the final PNG shows
    "Open With TextEdit (default)" followed by the next seven apps (the menu keeps 8; Launch Services' order, not
    alphabetical). Nothing was launched (`open` was never called).
- **Share, partly**: with the inspector open (`click:hello.txt;at:973,54;live:2;click:Share;live:3` at 1000x640 with one
  pane) the Share button reaches `Hooks.share` with the file's path and its anchor rectangle, and the hidden run does not
  crash, but `system_share.share` returns silently: `[NSApp keyWindow]` is nil in the hidden, inactive app
  (`isActive` false), so the picker is never created. The picker itself (and the anchor's y flip) still needs a person.
- **Still not verified in a running app** (need a visible, active window or real user input): the NSSharingServicePicker
  popover, launching an app from Open With, the real Quick Look panel's key handling (above), what a REAL keyboard
  event does to the menu (the CG-backed events above are the same kind of object, but only a keyboard produces
  Cmd+Backspace's `\x7f` or the arrow keys' F7xx characters), and volume mount/unmount notifications (the volume list at
  launch is verified).
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
