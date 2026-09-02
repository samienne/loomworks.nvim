# qmlls LSP integration

How the qmlls (QML language server) integration implements the core LSP
integration contract (`specification.md` §9). Lives at
`lua/loomworks/integrations/lsp/qmlls.lua`. Section numbers in this file
are local.

qmlls is deliberately a trimmed sibling of the clangd integration
(`spec/integrations/lsp/clangd.md`): it shares the cmd/root_dir factory
shape and the profile-restart hook, but drops clangd's OOM-adaptive `-j`
step-down, nvim LSP log rotation, and unexpected-exit restart policy.

## 1. Server name

`server = "qmlls"`. Modules emit `lsp_configs` entries with this server
name to route their projects through this integration. The cmake module
emits one unconditionally alongside its clangd entry (see
`spec/modules/cmake.md`).

## 2. Per-server entry fields

Beyond the core-defined `server` and `root_dir` fields (core §8.4
`lsp_configs`), this integration recognises:

| Field | Purpose |
|-------|---------|
| `binary` | Override server executable; `${ENV_VAR}` expansion supported. When unset/missing, the base `qmlls` on PATH is used |
| `binary_required` | When `true` and `binary` is missing, refuse to start and surface an error |
| `build_dir` | Absolute CMake build directory. qmlls resolves QML imports against this tree (passed as `-b <dir>`) |
| `import_paths` | Optional list of extra QML import paths, each passed as `-I <path>` |

Modules typically populate `build_dir` from the active ConfigUnit's build
directory — the same directory clangd receives as
`compile_commands_dir`. By the time the entry reaches this integration all
paths are fully resolved.

## 3. Per-buffer cmd resolution

The `cmd` function the integration installs into `vim.lsp.config` resolves
per buffer:

1. Look up the buffer's project in the workspace by `root_dir`.
2. If the project matches a loomworks qmlls entry:
   a. Override `args[1]` with `entry.binary` when it is set and exists on
      disk (after `${ENV_VAR}` expansion).
   b. Append `-b <build_dir>` when the referenced build directory exists.
   c. Append `-I <path>` for each entry in `import_paths`.
3. If `entry.binary_required` is `true` and the binary is missing: refuse
   to start and surface an error notification. **Do not fall back** to the
   base `qmlls`.
4. If no project matches: fall through to the base cmd passed into
   `cmd_factory` (the user's config, or the integration default
   `{ "qmlls" }`).

`-b` is emitted as two argv elements (`-b`, `<dir>`); each import path is
emitted as two argv elements (`-I`, `<path>`). These are the stable qmlls
flags on Qt 6.4+.

## 4. Per-buffer root_dir resolution

Same shape as cmd:

1. If the buffer matches a project: use `entry.root_dir`.
2. Otherwise: `vim.fs.root(bufnr, root_markers)` against the integration's
   defaults.

Excluded buffers (via core's `loomworks.lsp.excluded(bufnr)`) never match
— they get the fall-through path so the LspAttach detach hook can later
remove the client.

## 5. Default config

When the user calls `loomworks.setup({})` without an explicit `lsp` opt-in,
this integration's `default_enable = true` triggers installation with the
following defaults:

- `cmd = { "qmlls" }` — wrapped by `cmd_factory`
- `root_markers = { ".git", "CMakeLists.txt" }`
- `filetypes = { "qml" }`
- `capabilities` — auto-detected from completion plugins (see §6)

`default_enable = true` is safe for non-Qt users: qmlls only ever attaches
to the `qml` filetype, so a project with no `.qml` buffers never starts a
client. The integration also registers `.qml → qml` via `vim.filetype.add`
so the mapping is reliable.

## 6. Capability auto-detection

When the user does not pass `capabilities` in their setup config,
`build_config` auto-merges completion plugin capabilities on top of the
default LSP protocol capabilities:

- `blink.cmp.get_lsp_capabilities()` if blink.cmp is loaded
- `cmp_nvim_lsp.default_capabilities()` if cmp_nvim_lsp is loaded
- otherwise: stock `vim.lsp.protocol.make_client_capabilities()`

The user's explicit `capabilities` always wins.

## 7. Lifecycle hooks

- `on_active_set_changed()` — restart clients whose resolved `binary` or
  `build_dir` changed for the new active set. This is the profile-aware
  behavior: switching to a profile whose CMake build dir differs restarts
  qmlls so it re-resolves QML imports against the new tree. The restart
  goes through the `mark_managed_stop` path so the generic LSP throttle
  treats it as a managed stop.

This integration does **not** implement `on_workspace_changed`,
`on_unexpected_exit`, `reconcile_on_attach`, or `reset` — the generic
dispatcher tolerates their absence.

## 8. Status fields

`status_extras(entry)` reports per-server fields shown on the status page:

| Field | Source |
|-------|--------|
| `qmlls_bin` | `entry.binary` (or default `qmlls`) |
| `binary_required` | `entry.binary_required` |
| `qmlls_build_dir` | `entry.build_dir` |

## 9. User options

qmlls has no user-tunable flag block in this cut (unlike clangd's
`lsp.clangd` options). Opt-out is via `loomworks.setup` (see README): a
whole-server `{ lsp = { qmlls = false } }`, or replacing the `cmd` /
`filetypes` through `{ lsp = { qmlls = { … } } }`.
