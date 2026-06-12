# clangd LSP integration

How the clangd integration implements the core LSP integration contract
(`specification.md` §9). Lives at `lua/loomworks/integrations/lsp/clangd.lua`.
Section numbers in this file are local.

## 1. Server name

`server = "clangd"`. Modules emit `lsp_configs` entries with this server
name to route their projects through this integration.

## 2. Per-server entry fields

Beyond the core-defined `server` and `root_dir` fields (core §8.4
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

## 9. Flag injection

`cmd_factory` appends three categories of flags to every clangd cmd,
regardless of whether the user passed their own `cmd` or relies on
the integration defaults:

### 9.1 Always-on (no user opt-out)

| Flag | Effect | Available since |
|------|--------|-----------------|
| `--pch-storage=disk` | Store precompiled headers on disk rather than RAM. Single biggest RSS reduction on large TUs; pays a small I/O cost | universally supported |

Strict win on the workloads loomworks targets — large C++ projects
with multi-GiB clangd RSS. Negligible cost on small codebases. Not
exposed in the user-config schema; a workload that hates it should
file an issue rather than reach for an undocumented escape hatch.

`--malloc-trim` is intentionally **not** in this set even though it
would be a real memory win on Linux glibc. Older clangd builds reject
unknown args outright — notably the OpenHarmony SDK's clang-15-era
clangd refuses to start with `--malloc-trim`. Users on a modern
clangd can add it via `extra_args` (§12.1).

### 9.2 User-configurable (via §12 user options)

| Flag | Mapped from | Default |
|------|-------------|---------|
| `--clang-tidy` / `--clang-tidy=false` | `clang_tidy: bool` | `true` |
| `--background-index` / `--background-index=false` | `background_index: bool` | `true` |
| `--background-index-priority=<v>` | `background_index_priority: "low"\|"normal"\|"background"` | `"low"` |

The integration emits each of these unconditionally (with explicit
`=true`/`=false` for booleans) so the resolved cmd is self-describing
and immune to whatever the user already passed in their own `cmd`.
LLVM's `cl::opt` parser treats the last occurrence as authoritative,
so the appended form always wins.

### 9.3 Order

Flags are appended *after* both the user's base cmd and the dynamic
injections (`--compile-commands-dir`, `-j`):

1. user's base cmd (or integration default)
2. `--compile-commands-dir=<dir>` (when present)
3. `-j N` (when OOM step-down has kicked in)
4. always-on (§9.1)
5. user-configurable (§9.2)
6. `extra_args` from user.json (§12.1)

`extra_args` last so the user's own opinion overrides everything else.

## 10. OOM-adaptive `-j` step-down

The integration implements `on_unexpected_exit` (core spec contract
under §9 LSP integration restart policy). Per-root state tracks:

- `current_j` — the value appended to the cmd on the next start. `nil`
  before the first OOM means "leave the cmd alone" so the user's
  pristine arg list reaches clangd untouched.
- `retried_same_args` — one-shot flag for non-OOM crashes.

The first start for a root passes the cmd through verbatim — no `-j`
injection. On the first OOM we seed `current_j = 12` (a developer-
machine-friendly starting point) and append `-j 12` on the restart.
Each subsequent OOM halves the value (12 → 6 → 3 → 1). We don't bother
parsing or removing an existing `-j` from the user's cmd: clangd uses
LLVM's `cl::opt` parser where the last `-j` on the line wins, so a
plain append always overrides cleanly.

Decision table:

| Exit signature | Decision |
|---------------|----------|
| Linux signal 9 (SIGKILL) | OOM: seed `-j 12` on first, halve thereafter, restart |
| Windows exit code `0xC0000017` (STATUS_NO_MEMORY) | OOM: same |
| Windows exit code `0xC0000005` (access violation) | OOM heuristic: same (false positives are harmless — UI Reset puts it back) |
| Non-OOM, first occurrence | Restart once with same args |
| Non-OOM, second occurrence | Give up (lsp.lua notifies user) |
| OOM at `-j 1` | Give up (clangd needs more memory than fits) |

Adaptive state is in-memory only. Restarting nvim wipes `current_j`,
so the next session starts fresh from the user's cmd. A successful UI
`Reset` action (§12) calls `M.reset(root_dir)` which clears `_j_state`,
the cached `_resolved_cmd`, throttle attempts, and the generic lsp.lua
suppression flag — then re-enables clangd.

## 11. Log rotation

`cmd_factory` snapshots nvim's own LSP log file
(`vim.lsp.log.get_filename()`) on every clangd (re)start:

```
.log.5 ← .log.4 ← .log.3 ← .log.2 ← .log.1 ← copy(.log)
```

`LOG_KEEP = 5` snapshots are retained. We copy (rather than rename)
the live file because nvim's open handle stays attached to that path;
renaming is racy on Windows and on Linux would orphan the inode the
handle points at. Each snapshot captures everything nvim has logged
up to the moment of that restart, so the most recent one is the
postmortem to read after a crash.

Snapshots include other LSP servers' output too — the nvim log is
shared. That's an acceptable trade for not needing a clangd-specific
log capture wrapper. clangd is the most verbose server in practice
and the one most likely to die unexpectedly anyway.

## 12. User options (`user.json` → `lsp.clangd`)

A subset of clangd's behavior is configurable per-workspace via the
`lsp.clangd` block of `user.json` (core spec §2.2). Edits land via the
status-page LSP section (§13) and persist to disk on every change.

### 12.1 Schema

```json
{
  "lsp": {
    "clangd": {
      "clang_tidy": true,
      "background_index": true,
      "background_index_priority": "low",
      "extra_args": []
    }
  }
}
```

| Field | Type | Default | Effect |
|-------|------|---------|--------|
| `clang_tidy` | bool | `true` | Emits `--clang-tidy=true/false`. Disable when clang-tidy noise is unwanted or memory cost outweighs the diagnostics |
| `background_index` | bool | `true` | Emits `--background-index=true/false`. Disable when you want clangd quiet on first open (no indexing storm) |
| `background_index_priority` | `"low"\|"normal"\|"background"` | `"low"` | Emits `--background-index-priority=<v>`. `low` keeps the foreground request loop responsive; `background` is even gentler but noticeably slows index completion |
| `extra_args` | `string[]` | `[]` | Appended to the cmd last, after every other injection. Use for anything not typed: `--query-driver=`, `--malloc-trim`, custom flags. Each entry is one argv element |

All fields are optional. Omitted fields use the default. Validation
behavior:

- Unknown keys: logged at WARN, silently ignored.
- `background_index_priority` not in the enum: logged at WARN, the
  default `"low"` is used.
- `extra_args` not a string array: logged at WARN, ignored entirely.

### 12.2 Restart behavior

Changing an option restarts every clangd client in the workspace so
the new cmd takes effect. The restart goes through the same
`mark_managed_stop` path as `on_active_set_changed` (§7), so the
generic LSP throttle (§9.6 in the core spec) sees it as a managed
stop and doesn't count it against the unexpected-death budget.

### 12.3 Storage

The `lsp.clangd` block lives only in `user.json`. It is **not**
publishable to `loomworks.json` — different developers on the same
project legitimately want different clangd settings (memory budget,
clang-tidy preference). The publish/working-copy model (§2.4) does
not apply.

## 13. UI Reset and option editor

The integration declares `reset(root_dir)` and `reset_label = "Reset
clangd -j"`. The LSPs section in the status page renders one row per
client whose integration exposes `reset` — pressing Enter calls it.
The action label flips to `(auto-restart suppressed)` when the user
has stopped the client (`:LspStop`); selecting the row in that state
also clears the suppression flag so the client comes back to life.

The LSP section also renders an **option editor group** at the top
of the section listing every clangd option from §12.1 with its
current value:

```
Server defaults (clangd)
  ▸ clang-tidy: on
  ▸ background-index: on
  ▸ priority: low
    extra args: (none)
```

Enter on a boolean row toggles. Enter on `priority` cycles through
the enum. Enter on `extra args` opens a `vim.ui.input` prompt with the
current value as a space-separated string; on submit the input is
tokenised on whitespace and stored as a string array. Empty input
clears the field; `D` (delete) also clears. Tokens with internal
whitespace need hand-editing in user.json — same limitation as the
project-side `cmd_array` editor. Every change calls
`Workspace:set_lsp_option("clangd", key, value)` which persists
user.json synchronously and restarts clients.
