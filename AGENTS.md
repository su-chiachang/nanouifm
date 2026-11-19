# AGENTS.md

Nanofm is a desktop app made with [nanoui](https://github.com/justrach/nanoui)
in Zig 0.17: native UI drawn by nanoui itself (Metal on macOS, its own CPU
renderer on Linux and Windows), from one codebase.

## Commands

```sh
nui build                       # compile (zig build)
nui test                        # the tests: views rendered offscreen with ui.Tester
nui snapshot --out shot.png     # build, then render the app to a PNG, no window
nui snapshot --out shot.png --script "click:Increment;click:Increment"
nui run                         # open the app's window (for people, not agents)
nui doctor                      # check Zig and the platform
```

Every command takes `--json` for output a program can read.

## Rules

- **Never open windows while working.** Check what the app looks like with
  `nui snapshot` (open the PNG), and what it does with tests through
  `ui.Tester` (`src/tests.zig`). `nui run` is for people.
- **A view is a function of the state.** `State.view` in `src/app.zig` draws
  everything each frame; widgets report input as they're drawn
  (`if (ui.button(c, "Save", .{}).clicked) …`). Keep ids stable with
  `ui.key(c, …)` for items in lists.
- **Every behavior gets a test** in `src/tests.zig`: `t.clickText`,
  `t.typeText`, `t.hasText`, `t.screenshot("/tmp/x.png")`.
- Script steps for `--script`: `click:TEXT`, `type:TEXT`, `key:enter`,
  `wait:SECONDS`, `live:SECONDS` (the real event loop), separated by `;`.

## Layout

```
build.zig       the app, `run` and `test` steps
build.zig.zon   nanoui, pinned
src/main.zig    the window (the only code that knows the real home folder)
src/app.zig     the root view and the keyboard shortcuts
src/tests.zig   imports the UI tests
src/ui/         model.zig (app state, Config, queued Actions), pane.zig, tab.zig (folder,
                history, selection, sort, listing), history.zig, selection.zig, listing.zig
                (the one disk-read seam), sidebar_model.zig + sidebar.zig, list_pane.zig,
                path_bar.zig, format.zig, style.zig; list keys/expansion: keys.zig, nav_ops.zig, list_nav.zig,
                expansion.zig, typeahead.zig; column view: column_model.zig, column_ops.zig,
                column_view.zig, column_preview.zig; opener.zig (injected file opener, null in tests);
                tests.zig + test_support.zig
src/core/       the UI-free core library (`zig build test-core`)
```

nanoui's README lists the widgets (`ui.div(c).row().gap(8)…`, text,
buttons, inputs, lists), `nanoui.kit` (menus, dialogs, toasts, tabs) and
`ui.motion` (springs, presence, layout animation).
