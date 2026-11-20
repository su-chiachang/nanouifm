# Verifying nanofm without showing a window

The unit tests (`zig build test`) render views offscreen with `ui.Tester` and fake every system hook. This page is
about the other half: checking the REAL system providers (icons, thumbnails, file watching, Quick Look, the menu bar)
in the bundled app, without a window on your screen and without sending any input to the operating system.

Rules that apply to every run below:

- Start the app only with `--nanoui-snapshot=PNG` (nanoui renders offscreen and exits). Never `zig build run` or
  `nui run` while working.
- Always point `NANOFM_STATE_DIR` at a temp folder, never at the real state folder.
- Use folders and files you created for the run. Reading real folders (the default layout lists your home) is read-only.
- No synthetic OS events (`CGEventPost`, AppleScript clicks, `cliclick`). Calling AppKit in-process on objects you
  create is fine.
- Kill anything you start (`pgrep -f nanofm` should be empty afterwards).

## How a hidden run behaves

```sh
sd=$(mktemp -d)                                   # temp state folder
NANOFM_STATE_DIR=$sd build/nanofm.app/Contents/MacOS/nanofm \
  --nanoui-snapshot=/tmp/shot.png --nanoui-script='live:2;click:notes.txt;live:3' --nanoui-wait=0
```

- **`live:SECONDS` pumps the real main run loop; `wait:SECONDS` does not.** `wait:` is simulated time. The real system
  providers (NSWorkspace icons, QLThumbnailGenerator thumbnails, the worker-thread listing runner, volume
  notifications) answer through `objc.dispatchMain`, so anything the script makes the view ask for stays at its
  placeholder if the snapshot follows a `wait:`. `--nanoui-wait` (before the script) pumps the loop too.
- **`click:TEXT` is an exact text match** and aborts the whole script, silently and without a PNG, when the text is not
  on screen. A folder restored from `state.json` is listed asynchronously, so put `live:2` before the first click.
- **`at:X,Y` clicks at a point** (the default window is 1000 x 640 points; a screenshot at 2x has twice the pixels).
- **`chord:` reaches the view, not the menu bar.** Menu-owned shortcuts (Cmd+K, Cmd+Y, Cmd+T, ...) do nothing there.
  Space and the arrow keys are not menu accelerators, so `chord:space` and `chord:down` work.
- `key:` accepts `enter|backspace|tab|escape|left|right`. `rclick:` / `rat:` send a right button, not the secondary
  click the rows listen for, so they do not open the in-view context menu.
- A `state.json` in the temp state folder decides what the panes show, which makes it possible to create or change
  files in a folder while the app runs:

```sh
cat > $sd/state.json <<EOF
{"favorites":[],"layout":{"pane":{"selectedTab":0,"tabs":["file://$T/"],"viewMode":"list"}},
 "pinned":[],"showHidden":false,"sidebarVisible":true}
EOF
```

- Beware shell globs when picking temp folders: `ql.*` also matches a log called `ql.log`.

## What was verified, and how

Everything here was observed with the bundled `build/nanofm.app` (or `zig-out/bin/nanofm`) under the flags above.

### File icons and QuickLook thumbnails

The default run (no script, `--nanoui-wait=6`) lists the real home folder: PNG, PDF, source and audio files each show
their Finder icon, folders the blue folder icon, volumes their eject buttons. Selecting a picture and opening the
inspector (`click:<name>;at:582,53;live:6` in the default 2x2 layout) shows the file's own pixels as the QuickLook
thumbnail; with `wait:25` in place of `live:6` it keeps the generic symbol however long it waits.

### File watcher, worker-thread listing runner, persistence

- Create a file and a folder in the watched temp folder 4 s after launch (`live:12` script, `touch` from the shell):
  both appear in the final PNG. That is the real `DirWatcher` plus the worker-thread reload.
- Open a new tab (`at:437,17;live:3` in a one-pane layout): `state.json` is rewritten with two tabs and
  `selectedTab: 1` (debounced save). A second launch with that state folder shows both tabs.

### Volumes

Attach a small disk image while the app runs (`hdiutil create -size 8m -fs HFS+ -volname NanofmProbe probe.dmg`, then
`hdiutil attach probe.dmg`): the volume appears in Locations with an eject button; detaching it makes it disappear.
A `-nobrowse` image does not appear (hidden volumes are skipped on purpose). Detach and delete the image afterwards.

### Quick Look panel

Folder with `hello-ql.txt` and a 16x16 `tiny.png`:

```sh
NANOFM_STATE_DIR=$sd zig-out/bin/nanofm --nanoui-snapshot=$sd/o.png \
  '--nanoui-script=live:2;click:hello-ql.txt;chord:space;live:5;chord:down;live:3' --nanoui-wait=0
```

With temporary stderr diagnostics (`std.c.write(2, ...)`; `std.debug.print` does not work in nanoui apps), since
removed: the command ran with the hook installed and one path; the shared `QLPreviewPanel` was obtained; the data
source and delegate were set; QuickLook called `numberOfPreviewItems` and `previewItemAtIndex:0` (an NSURL); after
`makeKeyAndOrderFront:` the panel was visible with one item. A read-only CoreGraphics window list (owner
nanofm/QuickLook, no screen capture) showed one on-screen window, `owner=nanofm layer=9 w=816 h=849` (the text
preview). `chord:down` moved the selection to `tiny.png`: the hook's `update` ran once with that path and the window
became `w=370 h=223` (the image preview). The panel went away with the process.

### Menu-bar key handling, window growth, Open With

Temporary diagnostics driven from a wrapper around the view in `main.zig` (since removed). After the first frames, in
process: walk `[NSApp mainMenu]` (title, `keyEquivalent`, `keyEquivalentModifierMask`, `isEnabled`) and call
`[[NSApp mainMenu] performKeyEquivalent:event]` with an NSEvent that is never posted to the OS. Build the event from
`CGEventCreateKeyboardEvent` + `CGEventSetFlags` + `+[NSEvent eventWithCGEvent:]`: it carries the characters AppKit
really computes (Shift+Cmd+D has `charactersIgnoringModifiers` = "D"; a hand-built `keyEventWithType:...` with "D" does
not match a menu key "d"). The source contains no `CGEventPost`.

- The menu returns YES and the effect lands on the next frame for Cmd+T (tabs 1 to 2), Cmd+W (2 to 1), Cmd+D (panes
  1 to 2), Shift+Cmd+D (2 to 3), Ctrl+Cmd+S (sidebar hidden, then shown), Shift+Cmd+. (hidden files), Cmd+1 / Cmd+2
  (list / column), Shift+Cmd+N ("untitled folder" created), Cmd+K (palette opens), and, once the rename field no longer
  has the keyboard, Cmd+Z (listing 4 items to 3) and Shift+Cmd+Z (3 to 4).
- It returns NO, by design, for keys the view owns: Return, Cmd+Down, Ctrl+Tab, Space and Cmd+Backspace
  (`menu_link.ownsKey`), for Undo / Redo / Close Pane while disabled, and for every chord while a text field has the
  keyboard (`ui.suspendMenuKeyEquivalents`); the view's dispatcher (`command_keys.zig`, covered by the offscreen
  tests) takes them then. Cmd+K opens the palette through the menu path, which is why a script's `chord:cmd+k` does not.
- Window growth, with the screen's visible frame logged (1443 x 938): splitting one pane with Cmd+D leaves a
  1000-wide window alone for 2 panes, grows it to 1174 for 3 (x unchanged), to 1443 for 4 (x pushed to the screen's
  left edge), and stays at 1443 for 5 to 8 panes. It never shrinks. The resize lands one frame after the split. The
  snapshot's own Tester keeps 1000 x 640, so the PNG does not show the bigger window.
- Open With, the real provider (`system_open_with.list`): 12 apps for a `.txt` (TextEdit, the default, first) and 7
  for a `.png` (Preview first), no duplicates, no ".app" in names. The context-menu rows path was driven by calling
  `c.secondaryDown()` on the view's context with the mouse on a row (what `Tester.secondaryClick` does): the real
  provider was asked once and the PNG shows "Open With TextEdit (default)" plus seven more. Nothing was launched.

### Share, partly

`click:hello.txt;at:973,54;live:2;click:Share;live:3` (one pane, inspector open) reaches `Hooks.share` with the file's
path and anchor rectangle and does not crash, but `system_share.share` returns silently because `[NSApp keyWindow]` is
nil in the hidden, inactive app. The picker itself and its anchor's y flip need a person.

### Visible launch

Once, with the user's permission and no input sent: the bundled app stayed up for 10 s with no error output, idled at
0.0% CPU (about 108 MB) and exited cleanly on SIGTERM.

## Still needs a person

- The NSSharingServicePicker popover and its anchor placement.
- Launching an application from an Open With row.
- Keys on a real keyboard (Cmd+Backspace's `\x7f`, the arrow keys' F7xx characters) and, with the Quick Look panel
  key in a really active app: arrow keys, Escape, the close button, and whether QuickLook keeps a directly set data
  source (the hidden process is never the active app: `NSApp isActive` is false, the panel is not key).
