# loomworks.nvim — Architecture

How the plugin is built. What it must do is in [spec/plugin.md](spec/plugin.md)
(with [spec/integrations/](spec/integrations/) for the language servers and
debug adapters). Everything on the daemon side — `lw`, the workspace daemon,
the modules, the SDK providers, the workspace engine and the on-disk files —
lives in [samienne/loomworks](https://github.com/samienne/loomworks): see its
[ARCHITECTURE.md](https://github.com/samienne/loomworks/blob/main/ARCHITECTURE.md),
the wire protocol
[PROTOCOL.md](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md),
the interfaces
[API.md](https://github.com/samienne/loomworks/blob/main/spec/protocol/API.md)
and the file formats
[formats.md](https://github.com/samienne/loomworks/blob/main/spec/formats.md).

## What the plugin is

A thin client of one workspace daemon per workspace. The plugin holds **no
workspace model**: it does not read `loomworks.json`, the working copy or the
cache, never detects toolchains, never runs a build tool, and never removes a
build directory. It shows what the daemon's views say, sends the daemon
interface calls, and runs only what must run in the editor: language servers,
the debugger, a launched program's terminal, and the test explorer.

The coupling to loomworks is the protocol alone, plus a small set of files
vendored byte-identical from a loomworks release (below).

## Layers

```
 plugin/loomworks.lua   user commands
 lua/loomworks/init.lua public API facade, setup, keymaps, editor events
        │
 ┌──────┴───────────────────────────────────────────────────────────────┐
 │ UI           ui/status.lua + ui/sections/*  status page              │
 │              ui/*_editor.lua, ui/dialog.lua  editors and dialogs     │
 │              lualine/components/*            statusline              │
 │ Integrations lsp.lua + integrations/lsp/*    clangd, qmlls           │
 │              debug.lua, session_tracker.lua  nvim-dap, launch/debug  │
 │              loomtest_adapter.lua, neotest/  tests                   │
 │              fidget.lua, device_log.lua      progress, device logs   │
 ├──────────────────────────────────────────────────────────────────────┤
 │ Sources      status_source, lsp_source, test_source, device_source   │
 │              views.lua (the view store)                              │
 ├──────────────────────────────────────────────────────────────────────┤
 │ Daemon client daemon/observer.lua   the one connection per workspace │
 │              daemon/client/*         relay, framing, settings, version│
 │              daemon/editor_ops, facade, ui/model_calls  calls        │
 │              daemon/task_runner, remote_task, task_launch  tasks     │
 │              proto/*                 envelope, schemas (vendored)    │
 ├──────────────────────────────────────────────────────────────────────┤
 │ Provisioning provision/*             which lw, download              │
 └──────────────────────────────────────────────────────────────────────┘
        │  `lw daemon run --root <root> --stdio` (the relay)
        ▼
   lw workspace daemon (samienne/loomworks)
```

Upper layers call lower ones only. No UI or integration file talks to the
connection directly: reads go through a source, writes through a call module.

## `lua/` layout

| Path | Role |
|---|---|
| `loomworks/init.lua` | Public API: `setup`, workspace root, profile/target actions, event registration (`on`/`off`), getters over the views |
| `loomworks/auto_load.lua` | When to load a workspace (auto-load modes, root changes) |
| `loomworks/reload.lua` | Development: `:LoomworksReload` |
| `loomworks/health.lua` | `:checkhealth loomworks`: the observer, the selected `lw`, its probe |
| `loomworks/version.lua` | The plugin's version, from `CHANGELOG.md` |
| `loomworks/daemon/observer.lua` | Attaches to a root, selects and launches the relay, handshakes, subscribes to the views, follows signals and reconnects; degraded state when no usable daemon |
| `loomworks/daemon/client/relay.lua` | Spawns and ends the `--stdio` relay process; the only way to reach a daemon |
| `loomworks/daemon/client/framing.lua` | Framing and the frozen control subset on the editor side |
| `loomworks/daemon/client/settings.lua` | Settings and environment passed to the relay |
| `loomworks/daemon/client/version.lua` | What the editor's client speaks (transport and interface versions) |
| `loomworks/daemon/editor_retire.lua` | Retiring an idle, incompatible daemon |
| `loomworks/daemon/editor_ops.lua` | The editor's operations (build, configure, clean, reset, ...) as interface calls owning daemon tasks |
| `loomworks/daemon/facade.lua` | The public build / launch / debug entry points over `editor_ops` |
| `loomworks/daemon/launch_ref.lua` | A launch target as a daemon reference |
| `loomworks/daemon/task_runner.lua` | Each daemon task as one overseer task (strategy `loomworks_daemon`) |
| `loomworks/daemon/remote_task.lua` | A task observed from another client |
| `loomworks/task_launch.lua` | The editor's own overseer tasks: a launched program, a device log stream |
| `loomworks/views.lua` | The view store: `view.Header/1`, `view.Workspace/1`, `view.ProjectsIndex/1`, `view.Tests/1` as received, by id |
| `loomworks/status_source.lua` | The status page's reads of the views |
| `loomworks/lsp_source.lua`, `lsp_config.lua`\* | The LSP configuration (`LspConfig/1`) the LSP layer reads |
| `loomworks/test_source.lua`, `test_state.lua`\* | The tests view for loomtest |
| `loomworks/device_source.lua`, `device_log.lua`, `device_log_records.lua`\* | Devices and their log streams |
| `loomworks/lsp.lua`, `lsp_server_cmd.lua`, `integrations/lsp/{clangd,qmlls}.lua` | LSP dispatch: server setup, per-buffer status, deferred start until the workspace is ready, withheld servers |
| `loomworks/debug.lua`, `session_tracker.lua` | nvim-dap: adapters by language; the build → deploy → launch/debug chain |
| `loomworks/loomtest_adapter.lua` | The daemon's tests as a loomtest adapter |
| `loomworks/neotest/init.lua` | A neotest adapter that only refuses, pointing to loomtest |
| `loomworks/fidget.lua` | Task progress in fidget |
| `loomworks/ui/` | Status page (`status.lua`, `view.lua`, `tree.lua`, `helpers.lua`, `sections/`), dialogs and editors, `actions.lua`, `model_calls.lua` (the page's one route to model writes), `remote_output.lua` |
| `loomworks/description.lua`\*, `root_finder.lua`\*, `sha256.lua`\* | Descriptions, the workspace-root search, SHA-256 |
| `loomworks/proto/*`\* | Message envelope, schema documents and validator, conformance replay, task output bytes |
| `loomworks/provision/*` | The managed `lw` (below) |
| `loomtest/` | The test explorer, independent of loomworks ([LOOMTEST.md](LOOMTEST.md)) |
| `lualine/components/` | `loomworks` (active profile) and `loomworks_lsp` (withheld server) |

\* vendored from loomworks.

## Data flow

1. **Attach.** `auto_load` (or `:LoomworksInit`) gives `init.lua` a root. The
   observer selects an `lw` (`provision/select`), probes it, and spawns the
   relay `lw daemon run --root <root> --stdio`. The relay launches or finds the
   shared daemon and forwards its `welcome`; the observer checks versions
   (`daemon/client/version`, `Root.describe`) and subscribes.
2. **Views in.** The daemon pushes the views; `views.lua` keeps them as
   received. A view change emits an editor event; the sources turn views into
   what their consumers need (`status_source` for the page, `lsp_source` for
   language servers, `test_source` for loomtest, `device_source` for devices).
3. **Render.** The status page, lualine and the LSP layer read the sources
   only. They never compute workspace state themselves; ids from the views
   name entities in every call.
4. **Calls out.** Page actions go through `ui/model_calls` (model writes) or
   `daemon/editor_ops` (operations); keymaps and the public API go through
   `daemon/facade`. An operation's reply starts a daemon task; its frames
   stream into overseer through `daemon/task_runner`, and the resulting model
   change arrives back as a view update (step 2).
5. **Degraded.** When there is no usable `lw` or daemon, the observer reports
   why; the page shows the workspace unloaded with that reason. There is no
   in-process fallback.

## Provisioning the managed `lw`

`provision/` finds or installs the `lw` the observer launches:

- `select.lua` — `LOOMWORKS_LW`, `binary.path`, `lw` on `PATH`, the managed one
  (`binary.prefer` reorders); `probe.lua` caches a pre-launch compatibility
  verdict; `needs.lua` states what a release must offer.
- `pinned.lua` — the release the plugin pins: its version and the SHA-256 of
  each host binary, taken from the release's signed `SHA256SUMS` by
  `scripts/release/pin.sh`.
- `fetch.lua` — download next to `<stdpath("data")>/loomworks/lw/<sha256>/`,
  compare the SHA-256 with the pinned one, install by rename.
- `managed.lua` — the layout of the managed slots;
  `channel.lua` — stable/unstable upgrades; `cache.lua` — pruning of unused
  slots (paused, samienne/loomworks#101).

Deletion is limited to the plugin's own temporary files; see the
deletion-safety rules in `AGENTS.md` and §19.16 of the spec.

## Vendoring

The files marked \* above and `spec/protocol/**` are copied byte-identical
from a loomworks release by `scripts/vendor.sh` and listed with their hashes in
`VENDOR.MANIFEST` (`scripts/vendor.sh --check` verifies). They are never
edited here: change them in loomworks, tag, re-vendor. `.gitattributes` keeps
them free of line-ending conversion.

## Tests

`make test` runs every `tests/*_spec.lua` (plenary/busted) in its own headless
Neovim (`scripts/run_specs.lua`). The daemon specs run against a real `lw`:
`scripts/test_lw.lua` provisions the release the plugin pins into `.lw-test/`
with the plugin's own download code, and the Makefile points `LOOMWORKS_LW`
at it. `make test-file FILE=...`
runs one spec. Fixtures (`tests/fixtures/`) include status-page golden files,
a stub device module and SDK, and a fake relay process.
