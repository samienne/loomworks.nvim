# clangd LSP integration

How the clangd integration implements the core LSP integration contract
(`specification.md` §10). Lives at `lua/loomworks/integrations/lsp/clangd.lua`.
Section numbers in this file are local.

## 1. Server name

`server = "clangd"`. Modules emit `lsp_configs` entries with this server
name to route their projects through this integration.

## 2. Per-server entry fields

Beyond the core-defined `server` and `root_dir` fields (core §9.4
`lsp_configs`), this integration recognises:

| Field | Purpose |
|-------|---------|
| `binary` | Override server executable; `${ENV_VAR}` expansion supported |
| `binary_required` | When `true` and `binary` is missing, refuse to start and surface an error. Use when stock PATH `clangd` would be actively wrong (e.g., SDK clangd required for platform headers) |
| `compile_commands_dir` | Absolute directory containing `compile_commands.json` |

Modules typically populate `compile_commands_dir` from a ConfigUnit's
build directory. They may resolve cross-configuration references
internally (e.g., redirecting to another configuration's build dir for
a `compile_commands_from` setting) — by the time the entry reaches
this integration, all paths are fully resolved.

## 3. Per-buffer cmd resolution

The `cmd` function the integration installs into `vim.lsp.config`
resolves per buffer:

1. Look up the buffer's project in the workspace.
2. If the project matches a loomworks clangd entry:
   a. Override the base cmd with `entry.binary` when present.
   b. Append `--compile-commands-dir=<dir>` when the referenced
      `compile_commands.json` exists.
3. If `entry.binary_required` is `true` and the binary is missing:
   refuse to start, surface an error notification. **Do not fall back
   to the base `clangd`** — a wrong binary could index successfully
   against the wrong sysroot and produce subtly broken results.
4. If no project matches: fall through to the base cmd passed into
   `cmd_factory` (the user's config, or integration defaults).

This lets a single nvim session transparently use an SDK clangd for
buffers inside a workspace project and the user's stock clangd for
buffers outside any workspace.

## 4. Per-buffer root_dir resolution

Same shape as cmd:

1. If the buffer matches a project: use `entry.root_dir`.
2. Otherwise: `vim.fs.root(bufnr, root_markers)` against the
   integration's defaults.

Excluded buffers (via core's `loomworks.lsp.excluded(bufnr)`) never
match — they get the fall-through path so the LspAttach detach hook
can later remove the client.

## 5. Default config

When the user calls `loomworks.setup({})` without an explicit `lsp`
opt-in, this integration's `default_enable = true` triggers
installation with the following defaults:

- `cmd = { "clangd" }` — wrapped by `cmd_factory`
- `root_markers = { ".clangd", ".clang-tidy", ".clang-format",
  "compile_commands.json", "compile_flags.txt", ".git" }`
- `filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" }`
- `capabilities` — auto-detected from completion plugins (see §6)

## 6. Capability auto-detection

When the user does not pass `capabilities` in their setup config,
`build_config` auto-merges completion plugin capabilities on top of
the default LSP protocol capabilities:

- `blink.cmp.get_lsp_capabilities()` if blink.cmp is loaded
- `cmp_nvim_lsp.default_capabilities()` if cmp_nvim_lsp is loaded
- otherwise: stock `vim.lsp.protocol.make_client_capabilities()`

The user's explicit `capabilities` always wins.

## 7. Lifecycle hooks

- `on_active_set_changed()` — restart clients whose resolved `binary`
  or `compile_commands_dir` changed for the new active set.
- `on_workspace_changed()` — restart all pre-existing clangd clients
  so they pick up loomworks-aware routing.

## 8. Status fields

`status_extras(entry)` reports per-server fields shown on the status
page:

| Field | Source |
|-------|--------|
| `binary` | Resolved from `entry.binary` or `"clangd"` |
| `binary_required` | `entry.binary_required` |
| `compile_commands_dir` | `entry.compile_commands_dir` (or `(not found)`) |
| `binary_resolved` | Whether the binary actually exists on disk |
