# AGENTS.md

Nanofm is a desktop app made with [nanoui](https://github.com/justrach/nanoui)
in Zig 0.17: native UI drawn by nanoui itself (Metal on macOS, its own CPU
renderer on Linux and Windows), from one codebase.

## Commands

```sh
nui build                       # compile (zig build)
nui test                        # the tests: views rendered offscreen with ui.Tester
zig build test -Dtest-filter=text # only the tests whose name contains text
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
                commands.zig (THE command registry: table of id/title/shortcut/enabled/checked/run, used by
                command_keys.zig, context_menu.zig and next the menu bar + palette; command.zig,
                command_id.zig, command_impl.zig); file ops: file_actions.zig (through the model's
                FileOperationService), file_target.zig, file_refresh.zig, clipboard.zig (internal),
                rename.zig + rename_view.zig (inline rename); hooks.zig (injected clipboard mirror / Reveal /
                Option, null in tests) + system_hooks.zig (main.zig only); context_menu.zig, row_input.zig,
                goto.zig (Go to Folder); watch.zig (live refresh, `Config.watch`); drops.zig (Finder drops
                and pane-to-pane drag); toolbar row: toolbar.zig (buttons, name filter field),
                toolbar_menu.zig (Sort and "..." popovers, drawn with context_menu.rows), filter.zig +
                filter_ops.zig (per-pane name filter: `Pane.filter`, `Listing.rebuild`'s `filter`);
                command palette (Cmd+K): palette_model.zig (state in `view_state.palette`, rows live in a
                retired-not-freed arena), palette_rows.zig (sections, fuzzy ranking), palette_ops.zig
                (open, requery, choose), palette_exec.zig (open folder/file here, new tab, split),
                palette_index.zig (file index over `Config.index` roots + sidebar folders, crawled by an
                injectable `Runner`: a thread in main.zig, a held or immediate one in tests),
                palette_view.zig; persistence: persist.zig (the core `StateStore` through `Config.store`: restore at
                launch, 400 ms debounced save by the frame clock + `Context.frameIn`, flush at quit; the model
                stays the owner), menus: menu_template.zig (THE menu bar as a pure function of the registry and
                the model), menu_bar.zig (main.zig only: installs it with `App.setMenu`, syncs item state in
                place), menu_link.zig (who owns a key, the menu or the view dispatcher: read its header);
                sidebar: sidebar.zig (view), sidebar_model.zig, sidebar_ops.zig (remove, add, move, eject, volumes,
                Add to Favorites), sidebar_menu.zig (context menu), sidebar_dnd.zig + drag_kind.zig (reorder and
                add-by-drag over nanoui's in-window drag payloads), volumes.zig (injectable Locations provider +
                `Signal`) + system_volumes.zig (main.zig only: NSFileManager/NSWorkspace);
                inspector and previews: inspector_view.zig (beside the list, `Pane.inspector`, Opt+Cmd+I), item_panel.zig (one
                item's preview + details + buttons, shared with column_preview.zig), inspector_info.zig, inspector_ops.zig,
                thumbs.zig (bounded async thumbnail cache over `Hooks.thumbnail`), image_info.zig (PNG/JPEG/GIF size from the
                header, `Hooks.image_size`), file_icons.zig (bounded async per-file-type icon cache over `Hooks.file_icon`, asked by KEY: extension / folder / path for apps; at most 8 in flight) + row_icon.zig (draws it in list and column rows, path-bar crumbs and the inspector, generic symbol until it arrives), preview_state.zig (`Model.preview`); Quick Look: quick_look.zig (toggle + `sync` that
                follows the selection), quick_look_state.zig, `Hooks.quick_look`; main.zig-only system sides (never run in tests):
                system_quick_look.zig (QLPreviewPanel via objc.defineClass), system_thumbs.zig (QLThumbnailGenerator) + cg_pixels.zig, system_file_icon.zig (NSWorkspace icons, posted to the main queue),
                system_share.zig (NSSharingServicePicker); path_bar.zig crumbs are drop targets;
                async folder listing (`Config.listing`, null = every read inline, the test default): listing_loader.zig (the
                loader on `Model.loader`: requests with generations, bounded, `Intent` = what runs when the folders are in),
                listing_runner.zig (`Job.read` is the ONLY code that runs on a worker; `Job.deliver` runs on the main
                thread into an inbox), listing_inbox.zig (`Preloaded`: folders already read, taken by the ordinary code through
                `Tab.Opts.pre`), listing_apply.zig (`drain` at the start of `applyPending`: lands or drops results),
                system_listing.zig (thread + `objc.dispatchMain`, main.zig only). `Tab.Opts.loader` is non-null only when a
                runner is configured: `Tab.visit/back/forward/reload/setExpanded` and the column ops then REQUEST and return;
                file operations (`file_refresh.folders`) still read inline. Tests: `ts.ListingMode` (`.held` keeps jobs until
                `ts.releaseListing`), tests_async.zig;
                window_growth.zig (the window grows after a split or preset: `Hooks.window_frame`, system_window.zig, tests_growth.zig),
                open_with.zig (context menu "Open With <App>" rows over `Hooks.open_with`, system_open_with.zig, commands
                `file_open_with_0..7`, tests_open_with.zig);
                tests.zig, tests_*.zig + test_support.zig (`ts.Env`, `ts.IndexMode`, `ts.ListingMode`)
src/core/       the UI-free core library (`zig build test-core`)
```

nanoui's README lists the widgets (`ui.div(c).row().gap(8)…`, text,
buttons, inputs, lists), `nanoui.kit` (menus, dialogs, toasts, tabs) and
`ui.motion` (springs, presence, layout animation).
