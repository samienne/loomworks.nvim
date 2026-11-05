# loomworks.nvim — Plugin Specification

> **The core contract lives in loomworks.** The data model, the state machine,
> the module, SDK and device contracts, the headless host, trust, remote
> execution, the daemon and the invariants (core §1–§8, §10–§12, §15–§19) are
> specified in loomworks'
> [`spec/core/`](https://github.com/samienne/loomworks/blob/main/spec/core/README.md),
> with the module and SDK specs in
> [`spec/modules/`](https://github.com/samienne/loomworks/blob/main/spec/modules/)
> and [`spec/sdks/`](https://github.com/samienne/loomworks/blob/main/spec/sdks/).
> This file keeps only the editor client's sections; a reference
> "loomworks core §N" links the loomworks file that holds that section.

This is the normative specification of the Neovim plugin: a client of the
`lw` workspace daemon. The daemon, the `lw` CLI, the modules, the SDK
providers and the workspace engine live in
[samienne/loomworks](https://github.com/samienne/loomworks); their contract is
specified there — the wire protocol in
[`spec/protocol/PROTOCOL.md`](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md),
the interfaces in
[`spec/protocol/API.md`](https://github.com/samienne/loomworks/blob/main/spec/protocol/API.md)
and the on-disk files in
[`spec/formats.md`](https://github.com/samienne/loomworks/blob/main/spec/formats.md).
This repository vendors the protocol documents under [`protocol/`](protocol/)
(see `VENDOR.MANIFEST`; never edit them here).

Companion specs in this repository:

- [`integrations/lsp/`](integrations/lsp/) — clangd, qmlls
- [`integrations/debug/`](integrations/debug/) — codelldb, cppdbg, pwa-node

**Layout.**

- **Part I — The editor client**: the editor-side sections of the former core
  specification (§9 LSP integration, §13 auto-load, §14 Neovim commands, §18.11
  remote execution in the editor, §19.16 the editor as a client, including the
  managed `lw` and its bundle).
- **Part II — UI**: the status page, highlight groups and the statusline
  component (the former `spec/ui.md`; its section numbers are local to Part II,
  and "core §X.Y" in it means a section of Part I).

Section numbers are the original global numbers of the former core
specification; they do not restart per part, and loomworks' `spec/core/` keeps
the same numbers. A bare reference "§N" means that section in this file;
"loomworks core §N" and "loomworks spec …" link a section that lives in
loomworks.

# Part I: The editor client

## 9. LSP Integration

LSP integration is split between a thin core dispatch layer
(`lua/loomworks/lsp.lua`) and per-server integration files
(`lua/loomworks/integrations/lsp/<server>.lua`). Core is module-agnostic:
modules emit opaque `lsp_configs()` entries keyed by `server` name, and
core routes them to the matching integration. Integrations are discovered
from every runtime path, so drop-in integrations (either in the user's
own config or in a sibling plugin) register automatically alongside the
built-in ones.

### 9.1 Module interface ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md) `lsp_configs`)

Modules produce entries shaped as `{ server = "...", root_dir = ...,
db_state = ..., <per-server fields>... }`. Core inspects `server` to
dispatch and `db_state` ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) to decide whether the entry can back a
server at all (§9.8); integrations parse the remaining fields. Modules
may traverse core domain objects (Project, ConfigUnit) to resolve
cross-configuration references inside themselves, so paths emitted in
the entry are fully resolved.

**Database only from a unit configured here.** Inside a workspace, a
module supplies a compilation-database location (or any other
build-directory-derived server input) only from a ConfigUnit that is
**configured on this machine** — recorded as configured in the signed
cache ([loomworks core §17.8](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)). A unit that is not configured here (never configured,
reset, deleted, or configured only on another machine whose build
directory came with the copy) contributes no location: whatever database
its computed build directory may hold on disk is stale or foreign and is
never handed to a server. Instead the entry reports
`db_state = "unconfigured"`. The same holds when there is no active
profile, or the active profile maps no unit for the project. When the
module redirects the database to another unit (a cross-configuration
reference), the rule applies to the unit actually supplying the database.

### 9.2 Dispatch layer (`lsp.lua`)

Responsibilities:
- **Discover and load integrations on startup.** `lsp.lua` scans every
  runtime path for `lua/loomworks/integrations/lsp/*.lua` via
  `vim.api.nvim_get_runtime_file` and requires each file. Each
  integration self-registers by calling `require("loomworks.lsp").register(server, M)`.
  This means integrations can live in the plugin itself, in the user's
  own `~/.config/nvim/lua/loomworks/integrations/lsp/`, or in another
  plugin on the runtime path — all three are discovered automatically.
- **Expose generic factories** — `loomworks.lsp.cmd(server, base_cmd)`
  and `loomworks.lsp.root_dir(server, fallback)` delegate to the
  registered integration. Server-specific aliases (e.g.,
  `clangd_cmd`/`clangd_root_dir`) are kept as thin back-compat wrappers
  in the relevant integration file.
- **Wire integration listeners.** On startup, `lsp.lua` subscribes once
  to the daemon's LSP state changes (§19.16 "LSP configuration") and calls
  every integration's `on_active_set_changed` hook when the state switches
  or its entries change. Integrations don't register listeners themselves.
- **Provide `get_status()`** iterating all projects, calling each
  module's `lsp_configs()`, matching LSP clients by root_dir per server,
  and delegating per-server status fields to each integration's
  `status_extras(entry)` callback.

Core never references specific LSP server names. Adding a new server
means adding an integration file — no changes to `lsp.lua`.

### 9.3 Integration contract

Each `integrations/lsp/<server>.lua` returns a table with these fields
(all but `server` optional):

| Field | Purpose |
|-------|---------|
| `server` | Server name — must match `entry.server` |
| `build_config(user_cfg) → table` | Returns the full `vim.lsp.config` payload. Called by `setup_servers()` — merges user overrides with integration defaults, installs function-based `cmd` and `root_dir` |
| `default_enable` | `true` if this integration should be enabled when the user calls `setup({})` with no explicit `lsp` opt-in |
| `cmd_factory(base_cmd) → fn` | Builds a `cmd` function — used by `build_config` and exposed for users who prefer lspconfig |
| `root_dir_factory(fallback) → fn` | Builds a `root_dir` function — same pattern |
| `get_resolved_cmd(root_dir) → string[]\|nil` | Last-resolved cmd args (status display) |
| `status_extras(entry) → table` | Per-server fields merged into `extra` on the status page |
| `withhold_reason(entry) → string\|nil` | Whether this entry can back a running server (§9.8). Returns `nil` when the server may start for buffers routed to the entry, or a reason string when it must be **withheld** — `"unconfigured"` (the entry's `db_state` is `"unconfigured"`) or `"no_db"` (the unit is configured here but the server's required database is absent). An integration without the hook never withholds; its server starts as before |
| `on_active_set_changed()` | Called on profile/active-set change |
| `on_workspace_changed()` | Called on workspace swap / first load |
| `on_unexpected_exit(info) → decision` | Restart policy for an unexpected client death (see §9.6). `info` carries `{ server, root_dir, exit_code, signal, attempt, args }`. `decision` is `{ restart: boolean, args?: string[], reason?: string }` |
| `reset(root_dir)` | Clear any adaptive state for a root (UI Reset action) |
| `reset_label` | Display label for the UI Reset row |
| `health_inventory(ctx) → Declaration[]` | Environment-inventory declaration for this server ([loomworks core §16.33](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md), category *language servers*). The probe locates the server binary through the filesystem and executable search path only — never an editor API — so it runs in both hosts. Because the integration file itself may need editor-only facilities at load, the declaration lives in an **inventory companion**, loomworks' `lua/loomworks/integrations/inventory/<name>.lua` (a table with `health_inventory`), which `lw` discovers on its runtime path; the plugin carries no companion and the editor integration does not carry the hook (the editor reaches no inventory code: `lw health` runs in the binary). A language server is never a workspace requirement ([loomworks core §16.33](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)). The companion may carry an optional static `languages` (`string[]`, the languages the server or adapter serves); a plain `lw health` probes and lists a language-server companion only when a workspace module names it in `lsp_servers` ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) or, failing that, when its `languages` meet the workspace's, and a debug-adapter companion ([loomworks core §8.9.6](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) only when its `languages` do — a companion with neither shows only under `lw health --all` ([loomworks core §16.36](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) |

The integration's module body calls
`require("loomworks.lsp").register(name, M)` as its last action, then
returns `M`. Discovery handles the rest.

### 9.4 Server installation (`setup_servers`)

`loomworks.setup({ lsp = ... })` controls which servers loomworks
installs via `vim.lsp.config` + `vim.lsp.enable`:

| `opts.lsp` | Behavior |
|------------|----------|
| unset or `{}` | Install every integration with `default_enable = true` using its own defaults; apply default buffer excludes |
| `false` | Skip entirely — no `vim.lsp.config` calls; integrations still wrap clients that other code started |
| `{ <server> = {...} }` | Install `<server>`; user fields (cmd, on_attach, capabilities, settings, …) merge with integration defaults |
| `{ <server> = true }` | Install `<server>` with integration defaults |
| `{ <server> = false }` | Skip `<server>` specifically |
| `{ excludes = ... }` | Override default buffer excludes. See below |

**Buffer excludes** apply uniformly to every integration loomworks
manages — no language server handles `diffview://`, `fugitive://`,
`quickfix`, etc. well, so loomworks suppresses attachment to those
buffers before `root_dir` resolution and detaches any client that
attaches via filetype match (via an `LspAttach` autocmd). Defaults:

| Field | Default |
|-------|---------|
| `bufname_patterns` | `{ "^diffview://", "^fugitive://", "^octo://", "^gitsigns://", "^term://" }` |
| `buftypes` | `{ "help", "quickfix", "prompt", "nofile", "terminal" }` |

User override forms for `opts.lsp.excludes`:

| Form | Behavior |
|------|----------|
| unset (no `excludes` key) | Use defaults |
| `false` | Disable exclusion entirely |
| `{ bufname_patterns = {...}, buftypes = {...} }` | Replace defaults wholesale |
| `function(defaults) return ... end` | Receive a fresh copy of defaults, return the modified excludes (extend pattern) |

`loomworks.lsp.default_excludes()` returns a fresh deep copy of the
defaults so users can build extensions without touching internal state.
`loomworks.lsp.excluded(bufnr)` returns whether a given buffer is
excluded under the currently resolved excludes; integrations call this
from their `root_dir_factory` so excluded buffers never get matched to a
workspace project.

The integration's `build_config(user_cfg)` always wraps `cmd` and
`root_dir` with loomworks functions — the user's `cmd` becomes the
base/fallback passed into `cmd_factory`. This lets a single nvim session
transparently use a workspace-resolved server inside a project and the
user's stock server outside any project.

Footgun: if the user calls `vim.lsp.config("<server>", { cmd = ... })`
*after* `loomworks.setup`, their static cmd replaces loomworks' wrapping
function. On `VimEnter`, loomworks compares the installed cmd against
the currently-registered one; any mismatch triggers a single warning
pointing the user at the fix.

### 9.5 LSP integration implementations

Each integration shipped with loomworks documents its server-specific
fields, lifecycle, and status display in its own spec file:

- [`spec/integrations/lsp/clangd.md`](integrations/lsp/clangd.md)
  — clangd (C/C++/Objective-C/CUDA), with SDK-aware binary resolution
  and per-buffer `compile_commands.json` routing.

Third-party integrations follow the same shape: implement the
contract above and document the per-server fields alongside.

### 9.6 Restart on unexpected exit

`lsp.lua` wraps every managed client's `on_exit` so it can distinguish
three exit modes and route them correctly:

| Mode | Trigger | Action |
|------|---------|--------|
| Managed stop | Integration called `lsp.mark_managed_stop(client.id)` before `client:stop()` (e.g. its own `on_active_set_changed` restart) | Skip dispatch — the integration is restarting itself. |
| Clean external stop | `exit_code == 0` and `signal in {0, 15}` and not managed | Set per-`(server, root_dir)` suppression flag — `:LspStop` is the user's hard kill, no auto-restart until a fresh `LspAttach` or UI Reset clears it. |
| Unexpected death | anything else | Dispatch to the integration's `on_unexpected_exit(info)`. If it returns `restart = true`, re-enable the server through nvim's normal path (the integration's `cmd_factory` will run again with whatever adaptive state it keeps). |

A generic throttle caps restart velocity at **4 attempts per 5-minute
sliding window** per `(server, root_dir)`. When the cap is reached,
subsequent attempts defer until the oldest timestamp falls out of the
window. There is no permanent give-up at the lsp.lua layer — `:LspStop`
remains the user's escape hatch.

`lsp.lua` exposes:

- `mark_managed_stop(client_id)` — integrations call this before stopping their own clients
- `wrap_on_exit(server, user_on_exit) → fn` — integrations install this as `config.on_exit` from `build_config()` so the user's `on_exit` still runs and our dispatcher gets a turn after
- `is_suppressed(server, root_dir) / clear_suppression(server, root_dir) / reset_attempts(server, root_dir)` — public so the UI Reset action can recover from suppression and throttle without touching server-specific code

Adaptive state (e.g. clangd's `-j` step-down) lives entirely inside
the integration. Core sees only the opaque `LspRestartDecision`.

### 9.7 Deferred start until workspace-ready

A language server loomworks installs (the default path — §9.4) is **held from starting until the workspace has resolved**, so it starts exactly once with the correct binary and `compile_commands_dir` instead of starting against a default config and being restarted moments later.

The hold lives in the shared dispatch layer and works through the server's `root_dir` function, which loomworks owns. Neovim starts a client for a buffer only once `root_dir`'s asynchronous `on_dir` callback is invoked; loomworks withholds that callback for a buffer **under the workspace root** while the workspace is still initializing, queueing the buffer instead of resolving it. Buffers **outside** any workspace root resolve immediately via the fallback (`vim.fs.root`) — a C/C++ file unrelated to the workspace gets the user's stock server with no delay.

Because that decision is made from the **buffer's own path**, the hold also covers buffers restored *before* loomworks knows the workspace root: a session manager can reopen files — and Neovim can resolve their `root_dir` — before auto-load has called `setup` with the root. When no workspace is loaded yet and no configured root is known, the gate walks up from the buffer's path for a workspace marker (`loomworks.json`, or `.nvim/loomworks.user.json`); a buffer inside a loomworks workspace is held, one outside any is resolved. (A directory holding only `.nvim/loomworks.cache.json` is not a workspace — the markers are the two auto-load uses, §13.) Detection only *holds*: it never makes the buffer withheld. If, when the hold ends, no workspace is loaded or being loaded for the buffer's root (auto-load is cwd-based, so a file of another workspace opened from elsewhere loads nothing), the buffer is resolved through the fallback — the user's stock server, as for any buffer outside a loaded workspace (§9.8). Correspondingly a buffer counts as *ready to resolve* only once a **live workspace object** exists and its databases are ready — not merely because no workspace has loaded yet — and the start of a new initialization cycle never drains already-held buffers (they wait for that cycle's readiness signal or the safety timeout).

The queue is released when the **active profile's owned LSP databases are ready** — the compilation databases of its build directories that are configured here have been generated (a unit not configured here has nothing to generate and contributes no database, §9.1). At that point the resolved binary and the `compile_commands_dir` (with its `compile_commands.json` already on disk for configured units) are in place, so the server starts once, correct, with no follow-up restart. On release, each queued buffer is resolved normally (§9.8 *Decision*): it is routed to an entry — its project's, or for a buffer under the root outside every project the workspace entry — and, unless that entry is **withheld** (§9.8), its `on_dir` is invoked. A buffer whose entry is withheld is not started — it moves from the hold to the withheld set of §9.8. Databases for non-active profiles are generated lazily and do not gate the start.

Three terminal conditions end the hold so a buffer never stays in it indefinitely; none of them starts a server without a database for a buffer inside a workspace project:

- **No active profile / nothing to generate** — release immediately after the target scan. Project buffers resolve to entries reporting `db_state = "unconfigured"` and are withheld (§9.8); so are buffers under the root outside every project, since the workspace has no usable entry.
- **Initialization failure** (`workspace_changed` with no workspace) — there is no project to route to. Buffers under the failed workspace's root are withheld with reason `"workspace_error"` rather than started on the fallback (a fallback server would discover databases on its own and could pick up exactly the stale database this rule exists to avoid). They are re-evaluated when a later initialization succeeds.
- **Safety timeout** — if no readiness signal arrives within the bound, held buffers are resolved against whatever is known at that moment: a buffer whose entry is usable starts; one whose entry is withheld moves to the withheld set; a buffer under the root of a workspace that is still being loaded (setup pending, no live workspace object yet) is not started and keeps status `held` (§9.8) until that workspace arrives or fails, and is resolved then; a buffer for which no workspace is loaded or being loaded takes the fallback (stock server, status `none`). The timeout bounds the *gate*, never forces a database-less start inside a loaded workspace.

The hold spans the workspace's initialization **and** the generation of the active profile's owned database, so §9.4 cmd resolution finds `compile_commands.json` already present and appends `--compile-commands-dir` on the first start. Generation runs asynchronously and yielding ([loomworks cmake spec §12.2](https://github.com/samienne/loomworks/blob/main/spec/modules/cmake.md)), so this is a responsive wait, not a frozen UI; the completion-nudge ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) remains only as a safety net for a database that appears after a start (e.g. a manual reconfigure), not the normal path.

**Scope.** The hold applies only to servers loomworks installs. In the `lsp = false` opt-out path (§9.4) the user's own config starts the server; loomworks does not own `root_dir` there and cannot hold the start, so a client that attaches before the workspace is ready is repaired by the integration's attach-time reconciliation instead (per-integration; see the clangd spec). Excluded buffers (§9.4) are never held — they take the fall-through path regardless of workspace state.

### 9.8 Withheld servers for buffers without a usable database

Inside a workspace, a language server that needs a compilation database is **not started at all** for a buffer under the workspace root whose entry cannot supply one — rather than started without a database (where it would guess flags, or discover a stale database on its own) and producing misleading diagnostics. Outside any workspace nothing changes: such buffers get the user's stock server as before.

**Decision.** For each buffer under the workspace root, for a server whose integration implements `withhold_reason` (§9.3), the dispatch layer picks the buffer's entry and asks `withhold_reason(entry)`. `nil` → the server starts for that entry (via `on_dir` with the entry's `root_dir`, §9.7). A reason → the buffer joins the **withheld set** for that server; `on_dir` is not invoked and no client is created. Core never decides on its own which servers need a database — an integration without `withhold_reason` is never withheld and keeps its own routing. The entry is picked as follows:

- **Project buffer** — the entry its project's module emits for the server (§9.1). A project whose module emits no entry for the server has "no opinion": the buffer takes the fallback path, unchanged.
- **Buffer under the root outside every project** — the **workspace entry**: the first *usable* entry (one for which `withhold_reason` returns `nil`) among the entries the workspace's projects emit for the server, projects taken in ascending key order. The buffer joins that project's client and uses its database (clangd then infers flags for the file from the nearest database entries). If projects emit entries for the server but none is usable, the buffer is withheld — `"unconfigured"` when any of those entries reports it, `"no_db"` otherwise — so a server started from the fallback cannot discover a stale database under the root on its own (e.g. `<root>/build/compile_commands.json`). If no project emits an entry for the server, the fallback path is taken, unchanged.

Buffers outside the loaded workspace's root are never withheld; they take the fallback path (the user's stock server). With no workspace loaded, only buffers under the root of a workspace being loaded wait (`held`, §9.7); every other buffer — including one inside a workspace on disk that is not loaded — takes the fallback.

**Re-evaluation.** The withheld decision is re-evaluated, for every buffer the change can affect, on:

- an active-set / active-profile change (`active_set_changed`);
- a configure completing for a unit (its state changes to configured here) and the owned-database completion signal ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md) `refresh_lsp_database`'s `done`);
- any change that makes a unit no longer configured here — deletion, reset ([loomworks core §4.6](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md), [loomworks core §16.30](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)), out-of-band build-directory removal self-healed on remerge ([loomworks core §4.6](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)), a failed configure;
- a workspace swap or a successful initialization following a failure (`workspace_changed`);
- the workspace being shut down with no successor (`workspace_closed` — cwd swap teardown, reload): nothing is loaded, failed or pending any more, so held and withheld buffers under the old root take the fallback (stock server, status `none`); none stays withheld.

When a withheld buffer's entry becomes usable, the server is started for it exactly as a released buffer would be (its `on_dir` is invoked, or — when the earlier attach attempt has already completed without a client — the server's attach is re-run for that buffer), with no reopening by the user. The re-run attaches **only that server** (Neovim's own enable attach, for that one config: filetype check, `root_dir`, start with the config's client reuse) — it never re-resolves other servers enabled for the buffer. It requires the server to be enabled through `vim.lsp.config` + `vim.lsp.enable` (Neovim 0.11+; the §9.4 default path, or the user's own config built on it); a server started any other way gets its client on the buffer's next attach. When a running client's entry becomes withheld — typically a switch to a profile whose unit for that project is not configured here — the client is stopped through the managed-stop path (§9.6, so it is neither suppressed nor counted against the restart throttle) and its buffers join the withheld set. A changed-but-still-usable entry (different database directory or binary) is handled by the integration's own `on_active_set_changed` restart, unchanged.

**Per-buffer LSP status.** The dispatch layer records, per buffer, a generic status that UI consumers read (UI §3–§4):

| Status | Meaning |
|--------|---------|
| `none` | The buffer is not routed to a managed server by loomworks (outside any workspace, excluded, its project emits no entry for the server, no project emits one for a buffer outside every project, or no managed server for its filetype) |
| `held` | Waiting in the §9.7 hold (workspace initializing, database generating) |
| `ok` | A server was started (or is running) for the buffer with its entry |
| `withheld_unconfigured` | Withheld: the entry reports `db_state = "unconfigured"` (no active profile, or the active unit is not configured here) |
| `withheld_no_db` | Withheld: the unit is configured here but the server's database is absent (e.g. not yet generatable) |
| `withheld_error` | Withheld: the workspace failed to initialize (§9.7) |

When a buffer is routed to more than one managed server, the most severe status wins (`withheld_*` > `held` > `ok` > `none`). The status is exposed through the public API (`loomworks.lsp_buf_state(bufnr)`, and the `lsp` field of `buf_status()`).

**Scope.** Withholding is possible only where loomworks owns the server's start (§9.4 default path). In the `lsp = false` opt-out path the user's config starts the server; loomworks cannot withhold it, but §9.1 still holds — the entry carries no database location for a unit not configured here, so the integration never injects one — and the per-buffer status reports `none`.

---

## 13. Auto-load

### 13.1 Configuration

Auto-load is controlled by the `auto_load` setup option:

```lua
require("loomworks").setup({
  auto_load = "auto",  -- default
})
```

| Value | Behavior |
|-------|----------|
| `"auto"` | Always load silently when a workspace root is found from cwd (§13.2). Notify via `vim.notify`. |
| `"cached_only"` | Load silently if cache exists (`.nvim/loomworks.cache.json`). For uncached workspaces, notify but do not load. |
| `"prompt"` | Load silently if cache exists. For uncached workspaces, prompt the user for confirmation. |
| `false` | Never auto-load. Only manual `:LoomworksInit`. |

### 13.2 Triggers

Auto-load runs on:
1. **Plugin load** — checks cwd for workspace files
2. **`DirChanged` event** — checks new cwd for workspace files
3. **`SessionLoadPost` event** — re-checks cwd after session restore
4. **`User ResessionLoadPost` event** — re-checks cwd after resession.nvim
   session restore (safe to register even if resession is not installed)

Every check resolves the workspace root with the **upward root search of
[loomworks core §1.1](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)**, starting at cwd — the same search the headless host uses, so the
editor and `lw` resolve the same workspace from the same directory. The
search stops at a git working-tree boundary (a repository root or a linked
worktree) but continues through submodules, so Neovim started inside a
submodule of a superproject loads the superproject's workspace. Use
`:LoomworksInit` for a workspace outside that search (e.g. above a
repository root).

**Detection order**: at each directory, `loomworks.json` is checked first,
then `.nvim/loomworks.user.json`. Either file is sufficient to identify a
workspace root.

### 13.3 Behavior

When a trigger fires:
1. Search upward from cwd ([loomworks core §1.1](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) for a directory holding
   `loomworks.json` or `.nvim/loomworks.user.json` — that directory is the
   root.
2. If none found → no-op.
3. If found and a workspace is already loaded at that root → no-op.
4. If found and a **different** workspace is already loaded → prompt
   "Switch workspace to {name}?" regardless of `auto_load` mode.
5. If found and no workspace is loaded:
   - `"auto"` → load and notify: "Loaded workspace: {name}"
   - `"cached_only"` + cache exists → load and notify
   - `"cached_only"` + no cache → notify: "Workspace found at {root}
     (run :LoomworksInit to load)"
   - `"prompt"` + cache exists → load and notify
   - `"prompt"` + no cache → prompt: "Workspace found at {root},
     load? (y/n)"
   - `false` → no-op

### 13.4 Loading side effects

Loading a workspace (whether via auto-load or `:LoomworksInit`) connects the
editor to the workspace's daemon through a relay (§19.16 "Through the
relay"); the daemon loads the workspace when the editor connects (§19.16
"Loaded on attach"). The editor reads and creates none of the workspace's
files and detects no toolchains (§19.16 "End state"). The daemon's tasks
show their progress through fidget.nvim when it is installed (§19.16
"Tasks in the task runner").

### 13.5 Workspace initialization (`N`)

The editor does not create a workspace. `N` on the status page writes
nothing and shows an error notification: `creating a workspace is not
available with the workspace daemon — run lw init in a terminal` (§19.16
"Model writes"). `lw init` creates the workspace; the editor then loads it
as any other (§13.4).

### 13.6 Limitations

- **No file watching for workspace file creation**: If loomworks.json or
  user.json is created after Neovim starts and no `:cd` occurs, use
  `:LoomworksInit` manually.
- **No walking across repository boundaries**: the upward search ([loomworks core §1.1](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md))
  stops at a repository root or a linked worktree's root. A workspace
  placed above the repository root (or in a main checkout, when Neovim is
  started in a linked worktree) is not found — use `:LoomworksInit`, or
  `lw pull` to seed the worktree.

## 14. Neovim Commands

| Command | Args | Description |
|---------|------|-------------|
| `:LoomworksInit [path]` | Optional directory | Initialize workspace (default: cwd) |
| `:LoomworksInfo` | None | Open/focus status page |
| `:LoomworksDaemon [connect\|status]` | Optional subcommand (default: `status`) | `connect`: connect to the workspace daemon through an ordinary relay, which starts the daemon when none is live (§19.16 "Through the relay"); `status`: show the Runtime line and the host binary a launch would use, with its source (§19.16 "Host binary") |
| `:LoomworksTrust` | None | Review a refused working copy ([loomworks core §17.4](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)): show its summary, then trust (re-sign), discard, or cancel |
| `:LoomworksCompileCommand [file]` | Optional file (default: current buffer) | Refused: `compile command: not available with the workspace daemon` (§19.16 "Public API") |
| `:LoomworksLog` | None | Open the loaded workspace's `.nvim/loomworks.log` in a float; a note when no workspace is loaded or no log exists |
| `:LoomworksFidgetClear` | None | Cancel every tracked fidget progress entry and report how many were cleared |
| `:LoomworksReload` | None | Development: tear down the workspace and reload the plugin's code |

---


### 18.11 Remote execution in the editor

In this version the editor does not execute foreign targets: launch and debug
refuse through [loomworks core §18.1](https://github.com/samienne/loomworks/blob/main/spec/core/remote-exec.md) with the platform message, and test discovery never probes
a foreign executable ([loomworks core §18.1](https://github.com/samienne/loomworks/blob/main/spec/core/remote-exec.md)). Remote execution is headless only ([loomworks core §16.17](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md),
[loomworks core §16.34](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)); the editor launch chain is deferred (BACKLOG).

### 19.16 The editor as a client

**End state.** The editor is a **pure `lw` client**
of the **same daemon as the CLI**. It spawns `lw daemon run --root <root>
--stdio`, which connects to the workspace's shared daemon or starts it first
([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Connections"), and speaks the protocol through that relay; it reads
none of lw's internal files to connect, launch or follow a daemon, and holds
a keepalive ([loomworks core §19.11](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)). Only diagnostics may still read them, read-only:
`:LoomworksDaemon status` and `:checkhealth loomworks` may inspect the
handle, the runtime lock and the daemon logs to describe what they find;
nothing they read decides whether, when or to what the editor connects, and
they never write, remove or lock anything there. The relay needs a host
binary ("Host binary" below): with none the editor spawns no relay and runs
**degraded**: the status page shows the workspace unloaded with the reason,
language servers it manages are withheld ("LSP configuration" below),
operations are refused with that reason ("Availability" below), and nothing
of the workspace is loaded or run in the editor; it does not observe a
daemon another client started. **The editor holds no
workspace model**, connected or not: it loads none, detects no
toolchains or build targets, runs no file tracker on the workspace's files,
writes none of them (the cache included) and builds no view in-process.
Everything it shows comes from the daemon's views and replies, and every
public function answers from them ("Public API" below). Its tasks are
owned by its connection, so an editor that quits or crashes leaves no task
running; the daemon itself outlives it under [loomworks core §19.11](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md). Operations move from the
editor to commands in the order of [loomworks core §19.19](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md). When the shared daemon cannot be
started, the editor reports it and runs degraded; there is no
private-daemon fallback. The editor never runs the daemon code inside its own
process, nor a child daemon of its own.

**Through the relay.** The editor spawns the relay instead of reading the handle
and the machine key itself; "Launch" and "Connect" below then happen inside
the relay (loomworks spec [PROTOCOL.md §3](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md), [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Connections"). Before each spawn
it selects the host binary ("Host binary" below, with its pre-launch probe;
the selection may be cached for the session) and runs one of these forms of
`<binary> daemon run --root <root> --stdio`:

- **ordinary** (no further flag): connects to the workspace's daemon or
  starts it. Spawned on workspace load, on `:LoomworksDaemon connect`, on
  `retiring` and after the editor's own `retire`, and once per retirement
  episode after a status 16 ("Following a stopped or retiring daemon
  without relaunching it" below);
- **no launch** (`--no-launch`, [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "No launch"): waits for a daemon and
  never launches one. Spawned after a drop, after a status 10 or 11, and
  after a status 14 whose standard error has no `retiring` line the editor
  can parse;
- **retiring** (`--no-launch --retiring <pid>:<start_time>`, [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "A named
  retiring daemon"): waits for the named retiring daemon to exit. Spawned
  after a status 14 whose standard error names that instance ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)
  "Retiring-instance line");
- **skip** (`--no-launch --skip-instance <pid>:<start_time>`, [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Skip
  an instance"): "Skipping an incompatible daemon" below.

With no host binary the editor spawns no relay of any form and runs
degraded ("End state").

- **The relay process.** The editor spawns a relay hidden (no console window
  on Windows) and **not detached**, with plain pipes for its standard input,
  output and error, the per-user state directory ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)) as its working
  directory, and the environment it gives the selected binary for a daemon
  launch. It sets no handshake timeout of its own: each step of a relay is
  bounded inside the relay ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Connections"), and the waiting forms
  wait without a bound by design. These rules are normative:
  - The editor **never kills a relay's process tree**. On Windows the daemon
    a relay launched is a child of the relay by parent process id ([loomworks core §19.6.1](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)),
    so a tree kill would take down the shared daemon. The editor ends a
    relay by **closing its standard input** (the relay exits 0, [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md));
    only when the relay has not exited about 5 s later does it kill the
    relay's own process id — a plain kill, never its tree. That backstop
    timer does not keep the editor alive: at editor quit it never fires. On
    Windows the editor's process job then ends a relay still running; on
    POSIX a relay that ignores EOF on its standard input is orphaned. This
    is accepted (a relay exits on EOF; the backstop is for a hung one).
  - An older pin's attached `--stdio` runtime (a `welcome` without `via`,
    [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Compatibility") holds the workspace's runtime lock; it is ended
    the same way, by EOF on its standard input, never by a tree kill, so it
    releases the lock and cancels its tasks as a closing connection does.
  - The daemon **never inherits the relay's pipes**: the relay launches it
    detached with no inherited standard handles ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Launch"), so the
    editor sees EOF on the relay's standard output when the relay exits,
    whatever the daemon does, and ending a relay never reaches the daemon.
    End-to-end tests check that a daemon started through an editor relay
    survives the relay and the editor, and that no relay is left (`lw daemon
    list`) after teardown.
  - The relay's exit and the EOF on its standard output arrive in either
    order. The exit status is mapped ("Exit before `welcome`" below) only
    when the relay exits before the editor has received `welcome`; after
    `welcome`, any exit or EOF of the relay is a **drop** of the connection
    (the editor ends the relay as above). Before `welcome`, once the relay
    has exited the editor waits about 1 s for the EOFs still missing, then
    maps the status anyway. Once its standard output reached EOF the editor
    waits about 5 s for the relay's exit; a relay still running then is an
    internal error with no exit status — the editor waits with the
    internal-error note, as the "Exit before `welcome`" table's internal
    errors do (a relay that sends anything other than `welcome` first is
    treated the same) — and the editor ends it as above (closing its
    standard input, then the plain kill).
    A relay the editor ended itself (workspace swap, shutdown, a skip relay
    replaced) is not mapped.
  - The relay's last standard-error line is kept for the Runtime line's
    detail.
- It sends its usual `hello` (`client = "editor"`, `role = "observer"`) and
  judges the daemon from `welcome.daemon` exactly as it judges a `challenge`
  today, by the **editor's** compatibility rule ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Editor retirement",
  "Retiring an incompatible daemon" below), never the CLI's `lw_version`
  equality: the relay itself applies no version policy and never restarts a
  daemon on its own; only the editor's retirement does. The editor's `retire` goes over
  the relay connection, and only when `welcome.via = "relay"`. A `welcome`
  without `via` comes from an attached runtime of an older pin ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)
  "Compatibility"): the editor observes it **without the version check**
  (such a `welcome` carries no `welcome.daemon` to judge) and **never
  retires it**.
- **Waiting notes.** A relay reports nothing while it waits (on an attached
  run, a starting daemon, a retiring daemon, or for any daemon at all). Until
  it forwards `welcome` the Runtime line shows one generic note for its form:
  ordinary — connecting to or starting the workspace daemon (naming the
  binary and its source, as for a launch); no launch — waiting for a
  workspace daemon, none is launched (`:LoomworksDaemon connect` starts
  one); retiring — waiting for the retiring daemon to exit; skip — the
  incompatible-daemon note ("Connect" below). The relay reports no progress line.
- **Exit before `welcome`.** A relay that exits before `welcome` is mapped
  from its exit status ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Relay exit status") to a Runtime-line note,
  with the relay's `lw: ...` standard-error line as detail (never the
  status-14 `retiring` line), and a follow-up. "Wait"
  means: the editor stays degraded with that note and spawns no further
  relay until an explicit `:LoomworksDaemon connect` (or a workspace
  reload).

  | Status | Note | Follow-up |
  |--|--|--|
  | 10 | could not start the workspace daemon; the editor runs degraded | one no-launch relay, then wait |
  | 11 | the workspace daemon is not responding | one no-launch relay, then wait |
  | 12 | the daemon belongs to another loomworks data dir, or is not a loomworks daemon | wait |
  | 13 | the workspace daemon runs on another host | wait |
  | 14 | a retiring daemon is still busy | a retiring relay, or a no-launch relay ("Following a stopped or retiring daemon" below) |
  | 16 | the retiring daemon has exited and no other is live | the retirement episode's one ordinary relay, else wait |
  | 3 | the pinned `lw` predates the shared-daemon relay and another runtime holds this workspace (an older pin's attached `--stdio`, [loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Compatibility"); running degraded — update the pin | wait |
  | 1 | an internal error — or, for a repository pinned before 0.1.43-beta.15, the pin redirect's refusal ([loomworks core §16.23](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md) "A pin older than the command"), whose standard-error line names the pinned version and the release that introduced the command; the note shows that line | wait |
  | 2 | an internal error (usage) — or, when the relay was spawned with `--no-launch`, `--skip-instance` or `--retiring`, the pinned `lw <version>` does not support the editor relay flags (update the pin), naming the pinned version | wait |
  | 15 | an internal error (protocol) | wait |
  | 0 | an internal error (the relay ended although the editor kept its standard input open) | wait |
  | any other | an internal error | wait |

  "One no-launch relay" is one per failure: a no-launch relay spawned in
  answer to a status 10 or 11 is not answered with another when it, too,
  exits before `welcome` (it then follows the table's other rows or waits).
  A pinned release that predates a flag the editor passes (`--no-launch`,
  `--skip-instance`, `--retiring`) may answer with a usage status; that is
  status 2 above, and the editor still waits for an explicit
  `:LoomworksDaemon connect`. The note then names the pinned version (from
  `lw.pin`, [loomworks core §16.21](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) — that the pinned `lw <version>` does not support the
  editor relay flags — with the relay's usage line as detail, so the user is
  not left with a bare usage error. A status 2 from a relay spawned with none
  of those flags is the plain internal-error note.
- **Following a stopped or retiring daemon without relaunching it.** "No
  relaunch after a stop" and "Retiring" below watch the handle, which the
  editor no longer reads once it uses the relay; relays wait inside lw
  instead.
  - **Drop.** When the connection drops (after `welcome`) because the daemon
    stopped, crashed or dropped this observer, or the relay ended, the
    editor reconnects only through one no-launch relay, so `lw daemon stop`
    stays meaningful: the relay connects when a daemon appears, and the
    editor ends it ("The relay process") when it no longer wants one
    (workspace swap, shutdown).
  - **Retiring.** On `retiring` received over a live relay connection, and
    after its own `retire` succeeded ("Retiring an incompatible daemon"),
    the editor disconnects and spawns one ordinary relay, whose own wait
    (`RELAY_RETIRE_WAIT`) covers the retiring daemon and which launches the
    successor. This starts a **retirement episode**.
  - **Status 14.** When a relay exits 14 the editor waits through a relay
    that never launches: a retiring relay naming the retiring daemon, with
    the instance the exited relay's standard error named ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)
    "Retiring-instance line": the last line that is exactly `retiring
    <pid>:<start_time>`, the value being the daemon's instance id, [loomworks core §19.5](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) —
    e.g. `retiring 1234:win:5678`), passed as `--retiring
    <pid>:<start_time>`. Only when that line is missing or unparseable (a
    relay from an older pin, or a daemon without `start_time`) is it a
    plain no-launch relay. A status 14 also starts a retirement episode
    when none is open. Either relay connects to a successor another client
    starts. A plain no-launch relay can miss a daemon that exits before it
    first looks ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "A named retiring daemon"); it then waits as after
    a stop, until a daemon appears or an explicit connect.
  - **Status 16.** When that relay exits 16 (the retiring daemon is gone,
    no other is live) the editor spawns one ordinary relay, which launches
    the successor — at most **one per retirement episode**. A further 16 in
    the same episode is a note and a wait. The episode, and its count, end
    at the next `welcome` and on `:LoomworksDaemon connect`.
- **Skipping an incompatible daemon.** The editor learns that a daemon is
  incompatible only from `welcome.daemon`, after the relay connected; a new
  relay of either form would connect straight back to it. So when the editor
  does not observe an incompatible daemon — "Incompatible daemon" below,
  including once it declines to retire one it held a connection to ("Retiring
  an incompatible daemon") — it closes that relay, stays degraded, and
  spawns one `lw daemon run --root <root> --stdio --no-launch
  --skip-instance <pid>:<start_time>` naming that daemon from
  `welcome.daemon` ([loomworks core §19.10](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Skip an instance"). That relay never connects to
  it; it connects to a successor once one is live (another client launched
  it after the skipped one exited), and the editor judges that one afresh. Nothing is
  retried on a timer and the editor never launches over the skipped daemon;
  the relay exits 0 when the editor ends it (workspace swap, shutdown).
  The editor retires an incompatible daemon only over a relay connection
  (`welcome.via = "relay"`).
  A daemon whose start time is unknown (`welcome.daemon` without
  `start_time`) cannot be named with `--skip-instance` (an instance id needs
  both, [loomworks core §19.5](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)). When the editor finds such a daemon incompatible it closes
  that relay and stays degraded for the session; it spawns no skip relay,
  and retries only on `:LoomworksDaemon connect`.

**Interface client.** On every connect, including
each reconnect, the editor **discovers** the daemon through the root object
(`welcome.objects`, `Root.describe`; [loomworks core §19.20](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)), picks per interface the highest
version both sides support, and subscribes to the views and tasks it shows,
taking their full state from each subscription's `initial`. A missing or
incompatible interface degrades only the feature that needs it, with one
Runtime-line note naming the interface and both versions (e.g. `lsp
configuration: daemon offers loomworks.LspConfig/2, editor needs /1`); it
never fails the connection or the other features. The view features are
`statusline` (`loomworks.view.Header/1`) and `project index`
(`loomworks.view.ProjectsIndex/1`), beside `tasks` and `model changes`; a
degraded view is shown unavailable, never built in-process. The operation
features are `operations` (`loomworks.Build/1` with `configure`, `units`,
`jobs` and qualified targets), `launch` (`loomworks.Launch/1` with
`prepare_debug` and `build_scope`), `debug adapters`
(`loomworks.DebugConfig/1`) and, in `tasks`, `Tasks/1.cancel` and `list`;
a degraded one refuses its operations, never running them in-process
("Availability" below). When `lsp configuration` (`loomworks.LspConfig/1`)
is degraded the language servers are withheld, never configured in-process
("LSP configuration" below). When `tests` (`loomworks.Tests/1` with
`discover`, `run_cases`, `prepare_debug`, `collect` and `result`, and
`loomworks.view.Tests/1`) is degraded the test explorer shows tests
unavailable, never discovering or running them in-process ("Tests" below).
The describe is bounded
(about 3 s) and never blocks the editor; when it fails or times out the editor
uses `welcome.objects`. Between a lost connection and the reconnect the
editor's workspace is unloaded ("Unloaded on disconnect" below); the
reconnect's discovery and first reads end it. An interface that appears later (the root's
`objects_changed`) is subscribed to then, and a refused subscription is
retried once, on the next `objects_changed` or reconnect. A missing interface
is noted only when the editor gets nothing for it: a daemon whose
`describe` reports `delivery: "subscription"` sends a transport-11
connection only what it subscribed to, so a missing interface is noted; a
daemon of transport 11 without it (an older daemon, or a describe that failed)
still sends the protocol-10 broadcasts, and one that offers none of the
observed views is observed through them without a note. Only a transport mismatch
(no overlap of the ranges, [loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)) makes the daemon incompatible as a whole.
Against a daemon of protocol 10 (no `welcome.objects`) the editor observes
through the v0 broadcasts as below and notes interface features as "daemon
too old".

**Editor operations.** While connected to a compatible daemon, the editor runs these
operations as **interface calls**, owning their tasks ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "The editor as
owner"):

- builds — of a profile (`Build/1.build { profile }`), of configuration units
  (`units`), serial (`jobs = 1`). The status page names the
  profile and the units by its view rows' ids (`{ id }`, a unit row's
  `unit_id`), never by key; a row without an id offers no operation. Its
  cancel and task output of a row are the tasks whose meta names the row's
  ids ([API.md](protocol/API.md) §4.2) — cancel only for a task the editor
  owns;
- the build of a non-device launch target (`Launch/1.build`; the
  editor's *Build default target*), as one owned task — its dependencies, its
  pre-build deploy and its own build never run in the editor; its progress
  entry follows the task's current step ([API.md](protocol/API.md) §4.3). The
  artifact-conflict question is asked before the call, over the units it
  builds, and its answer sent as `force`;
- configures — of a profile or of units (`Build/1.configure`);
- module cleans — of a profile or of units (`Build/1.clean`), and the clean
  of a clean-and-build, followed by its build as a second call once the
  clean's task ended successfully;
- the preparation of run and debug launches of non-device targets
  (`Launch/1.prepare_run`, `Launch/1.prepare_debug`, both with `build_scope =
  "target"`, with `force` as for a build, the progress entry
  following the current step): the editor then runs the returned `launch` in its task runner,
  or hands the returned `debug` to its debugger (its adapter-specific shape
  and the installed-adapter check, made before the call, stay in the editor,
  [loomworks core §8.9.6](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md); the adapter checked is the one the daemon's mapping names,
  `DebugConfig/1.adapters`, while it is carried — never the editor's own
  mapping: while it is not carried, its read failed, or it does not name the
  language, nothing is checked before the call and the debugger checks the
  prepared adapter). A preparation that ends with
  `device = true` (a target found foreign by probing its artifact, [loomworks core §18.1](https://github.com/samienne/loomworks/blob/main/spec/core/remote-exec.md)) is **refused**: the editor does not execute foreign
  targets (spec §18.11), so no program is started and nothing of the run
  continues in the editor. Its error notification names the target and the
  remedy, `<target> runs on a device: the editor does not execute foreign
  targets (spec §18.11); run it with lw run`. Runner devices ([loomworks core §18](https://github.com/samienne/loomworks/blob/main/spec/core/remote-exec.md)) stay out
  of the editor. A device target of [loomworks core §11](https://github.com/samienne/loomworks/blob/main/spec/core/integrations.md) is launched through
  `Devices/1` ("Devices" below). The program is the editor's, never the daemon's; stopping a run or
  debug session stops that program. While the preparation runs, a stop
  cancels its task (`Tasks/1.cancel`) and no program is started, and a
  second launch asks, as for a running session, before it replaces it.
  While the workspace is unloaded — the daemon reports it
  `unloaded`, or the connection is lost ("Unloaded on disconnect" below) —
  a run or debug launch is not offered and, when asked for, is refused with
  that status, never prepared in-process: its launch information comes
  only from the daemon;
- the debug adapters section reads and writes `DebugConfig/1` (`adapters`,
  `known_languages`, `set_adapter`) and re-reads it on `Workspace/1`
  `changed`; while it is not carried the section is unavailable and its
  writes fail, as any operation is refused ("Availability" below).

Test runs and discovery go through `Tests/1` ("Tests" below);
device-target launches through `Launch/1.build` and `Devices/1` ("Devices" below). The editor runs no operation itself.

**Model writes.** The editor writes nothing
to the workspace's files and runs no deletion: every status-page action and
editor dialog that changes the model is a call to a command method of
[loomworks core §19.14](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md), naming its entities by the ids of `view.Workspace/1` — for a
project's variable, deploy destination or `type_config` field, the
project's id and the entry's name. A dialog reads what it edits with
`Projects/1.declaration` when it opens; a confirmation (a deletion, a nuke,
trust, the removal of the working copy) shows the `confirm` lines and sends
back their `plan`. A confirmed deletion first cancels the editor's own tasks
whose meta names the confirmation's `unit_ids` (or, for a profile, the
profile row's id) — never matched by key or path ([API.md](protocol/API.md)
§22); a confirmed nuke cancels every task the editor owns. A refused call (a stale id after a reload, a changed
plan, a held lock) is an error notification and changes nothing; the page
shows the views' next `update`. The editor never keeps an id across a
`header_changed` that reloaded the workspace. While a method's interface is
not carried the action is refused ("Availability"), never run in-process.
With no workspace loaded (its load failed, or a trust or schema refusal
unloaded it, as `view.Header/1`'s `state` reports it) every action is
refused, nothing sent and nothing run — the nuke, trust and the removal of
the working copy name their command (`lw nuke`, `lw trust`, `lw trust
--discard`). Creating a workspace (the status page's `N`, a new
`loomworks.json` where none is) is likewise refused, loaded or not, nothing
written: its error notification names `lw init` ([API.md](protocol/API.md)
§6 defers `Workspace/1.create` until a server serves a root with no
`loomworks.json`).

A confirmation the editor shows before an operation
(a clean's) is asked before the call ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Confirmation"); so is the
artifact-conflict question of a build ([loomworks core §5.9](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)) for the units whose artifacts
are known then (configured ones, as the view's unit rows report them, `artifact_block`, never from the editor's model), its Yes sent
as `force` — a conflict found only after the routed build's own configure
ends the task as the CLI's routed build does (the refusal naming `--force`). Each call
carries the editor process's whole environment **at call time**, under the
rules of [loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Environment" — what an in-process task of the editor
inherits.

**Availability.** The editor routes an operation only when it
can be carried; otherwise it refuses it. It is carried
while connected through interfaces to a compatible daemon that offers
`loomworks.Build/1` and `loomworks.Tasks/1` (its `cancel`: an operation the
editor could not cancel is not routed) and has not shown the method
missing on this connection:

- no connection (no host binary, a relay still starting, the daemon stopped,
  a daemon found incompatible — the editor never routes to one, including
  one with older schemas it only observes), or a feature degraded (its
  interface or method missing — an older daemon's `unknown_method`, or
  `invalid_args` for a parameter it lacks, means nothing ran): the operation
  is **not run**. It is refused at once with the observer's Runtime-line
  note as its message (e.g. `build: waiting for the workspace daemon
  (connecting)`, `operations: daemon offers no
  loomworks.Build/1.configure`); the action stays offered so the message is
  visible;
- `declined` (a foreign kit, trust, another environment while a build runs):
  the operation fails with the reason as one notification line;
- `refused`: the operation fails with the refusal's message;
- the connection lost **after** `accepted`: the operation fails ("the
  workspace daemon disconnected") and is **never re-run in-process** (for a
  launch: no program is started), as for the CLI ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Cancellation").
  An `internal` error from a call is handled as by the CLI ([loomworks core §19.20](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "The CLI's
  calls"): the operation fails and is not re-run.

There is no in-process fallback and no opt-out; the editor never runs
workspace logic itself.

**Public API.** The plugin's public functions answer
only from what the daemon gave the editor — its views, the `LspConfig/1`
state ("LSP configuration" below) and replies — never from a model (the
editor holds none, "End state"). A getter returns **plain tables**: copies
of the view rows that carry the facts, with their ids, which are what a
call's `{ id }` reference takes ([API.md](protocol/API.md) §1.2); writing
to a returned table changes nothing. While the view a getter reads is not
held (not yet connected, disconnected, not offered) it returns `nil`:

- `lw.get_profiles()` — `view.Workspace/1`'s `profiles` records, by key;
  `lw.get_active_profile()` — the record whose `active` is true;
- `lw.get_projects()` — its `projects` records, by key;
  `lw.project_for_buf(bufnr)` — the buffer's `view.ProjectsIndex/1` record,
  as `lw.buf_project` ([loomworks core §19.13](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md));
- `lw.get_config_sets()` — its `config_sets` records, by name;
  `lw.get_active_configuration_set()` — the record whose `active` is true;
  `lw.get_tool_entries()` — per configuration set name, the `profiles`
  records of that set;
- `lw.get_tools_by_type()` — per module type, the distinct `tools` rows
  (`{ module, key?, label }`) the `profiles` records select; the toolchains
  a module detects are `Toolchains/1.list`, a call;
- `lw.get_orphaned_configs()` — its `orphaned.configurations` records;
- `lw.get_lsp_options(server)` — that server's options in the held
  `LspConfig/1` state;
- `lw.get_workspace()` — always `nil`.

The pickers, build and launch functions act by calls, always on the active
profile row; a Profile argument is ignored:

- `lw.pick_profile()` lists the `profiles` records and sends
  `Profiles/1.set_active`. It offers no "None", because no call deactivates
  a profile.
- `lw.build_profile()` is `Build/1.build` of the active profile's id, an
  owned task as in "Editor operations". A failed reply that was not already
  notified is one warning: its message, else `build failed`.
- `lw.build_target()`, `lw.launch_target()` and `lw.debug_target()` act on
  the active profile's default target, which is the `Launch/1.targets`
  record marked `default`. They are its `Launch/1.build`, and the
  preparation of its run or debug (`Launch/1.prepare_run`,
  `Launch/1.prepare_debug`), as in "Editor operations". When the profile has
  no default target, the target picker opens first. Its choice is stored
  (below) and the action goes on with it. When the stored default no longer
  resolves (the row's `default_target_valid` is false), the editor first
  warns `target '<default_target>' no longer available` and then opens the
  picker.
- `lw.pick_target_action()` offers "Build" and "Switch target" on a valid
  default target (as the row reports it). Without one it opens the target
  picker.
- `lw.pick_target()` lists `Launch/1.targets`, in one call when it opens,
  with "None (clear target)" first. It sends the choice, or the removal of
  the stored choice, with `Profiles/1.set_default_target`
  ([API.md](protocol/API.md) §9.6, §11).

**A default target is addressed by its profile alone.** A call on the
profile's default target sends `profile` but no `target`, `project` or
`kind`. The daemon then resolves the profile's own stored default target
([loomworks core §16.17](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md) "Launch target selection"), including its descriptor's
`working_dir` override. A target rebuilt from its project, name and kind
would lose that override. Any other target is addressed by its project's
id, its name and its kind. A device target is reached only as the default,
so it is always addressed by its profile.
The deploy editor's source targets are `view.Workspace/1`'s
`projects[].targets`, joined by project id, so a project in no profile
offers its targets too. A refused or uncarried call is an error
notification and changes nothing ("Availability").
`lw.compile_command_for_file(file)` and `:LoomworksCompileCommand` are
**refused** — `not available with the workspace daemon` — and never read a
compilation database or a model.

**LSP configuration.** What the
editor's language servers are configured with — each project's
`lsp_configs` entries with their `db_state` (§9.1), the working copy's
per-server options ([loomworks core §2](https://github.com/samienne/loomworks/blob/main/spec/core/three-file-model.md), `user.json` `lsp`), and whether the active profile's
owned databases are ready (§9.7) — comes **only** from the workspace daemon,
as `LspConfig/1.get` answers it ([API.md](protocol/API.md) §13). There is no in-process fallback:
the editor never builds that state itself — it does not call `lsp_configs`,
derive a `db_state`, read options from its own model, generate or scan an
owned database, or map a buffer to a project other than by `lw.buf_project`
— and when the daemon cannot give the state, the servers wait or are
withheld (below), never configured from anything else. The daemon's state is
**in use** while the editor is connected through interfaces to a compatible
daemon that offers `loomworks.LspConfig/1` and the last read answered with
state `loaded`. The servers stay the editor's: starting and stopping them,
the integrations (found on the editor's runtime path, §9.2) with their `cmd`
and `root_dir` factories and `withhold_reason` (with its absent-database
check), the expansion of variables in a server binary, the §9.7 hold, the
per-buffer status (§9.8) and the restart throttle (§9.6). `get` carries the
editor process's whole environment at call time ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Environment"), so
an entry's server binary resolves as the editor would run it.

- **Reads.** The state is cached per connection and read again on
  `LspConfig/1` `changed`, on `Workspace/1` `changed` and on reconnect; the
  first read is made once the interface is discovered. A cached state is
  dropped when its connection is lost.
- **Readiness.** While the daemon's state is in use, the §9.7 hold is
  released on the state's `ready`; the editor model's own loading,
  readiness or failure takes no part in the hold or in any LSP decision.
  While the state is `loaded` but not `ready`, buffers under the root stay
  held, bounded by the §9.7 safety timeout, at which they are resolved
  against the daemon's state (a buffer whose entry has no usable database is
  withheld, never started).
- **Waiting.** While the editor waits for the daemon — the relay starting or
  connecting, the describe or the first `get` not answered, the state
  `unloaded` (the daemon has not loaded the workspace yet — "Loaded on
  attach" below), or the
  workspace unloaded because the connection was lost ("Unloaded on
  disconnect" below) — buffers under the root stay
  **held** (§9.8 status `held`) with **no timeout**: the §9.7 safety timeout
  does not apply, and nothing is resolved against another source. The
  Runtime line says so (`lsp configuration: waiting for the workspace daemon
  — language servers held`, UI §1.1). The hold ends when a read
  answers `loaded`, as under "Readiness".
- **Unavailable.** When the daemon cannot give the state — no host binary
  ("Host binary" below; the editor's other operations then run as that
  paragraph says, its language servers do not), a daemon found incompatible,
  `loomworks.LspConfig/1` missing or offered only at another version, a
  `get` that is declined or fails, or a state of `error` or `refused` (the
  daemon's load of the workspace failed or was refused) — buffers under the
  root are **withheld** (§9.8: `withheld_error` for a state `error` or
  `refused`, `withheld_daemon` otherwise), and the reason is the Runtime
  line's note in the warning highlight (e.g. `lsp configuration: daemon
  offers no loomworks.LspConfig/1 — language servers withheld`, `lsp
  configuration: no lw host binary — language servers withheld`). A
  declined or failed read is retried on the next `changed`, `Workspace/1`
  `changed` or reconnect; a state `loaded` re-evaluates the withheld buffers.
- **Running clients.** A lost connection stops every client of a server
  loomworks controls (§9.4 default path) under the root, through the
  managed-stop path (§9.6, so it is neither suppressed nor counted against
  the restart throttle), and its buffers become `held` ("Unloaded on
  disconnect" below); they start again only when the daemon, after the
  reconnect, reports the workspace `loaded` and their entry usable and
  `ready` (§9.7). Otherwise only a state in use changes a running client:
  when its entry becomes withheld it is stopped the same way (§9.8
  "Re-evaluation"). Waiting while connected, or an unavailable
  configuration, starts no client and stops none — a client started from an
  earlier state keeps running, and its buffers keep status `ok`, until a
  state in use says otherwise, which then restarts a client only when its
  resolved binary or database directory differs.
- **Owned databases.** Only the daemon generates the owned LSP databases
  ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md) `refresh_lsp_database`): the editor's model never does — not at its
  startup scan, not after a task, not on a watched path — whether or not the
  state is in use. A database the daemon (re)writes reaches the editor as a
  raised `db_rev` on its entry ([API.md](protocol/API.md) §13), on which the editor runs the
  owned-database completion handling of §9.8 for that entry.
- **Re-evaluation.** When a read gives entries or options that differ from
  the ones in use, or the state starts or stops being in use, the editor
  re-evaluates as for an active-set change (§9.8 "Re-evaluation"): a
  withheld or held buffer whose entry became usable is started, a client
  whose entry became withheld is stopped through the managed-stop path, and
  a changed but still usable entry restarts through its integration.
  Changed options are applied as an option change (clangd: its spec §12.2).
- **Options.** A per-server option the editor sets (the status page's LSP
  section) is written **only** by `LspConfig/1.set_option`; the editor
  never writes `user.json` `lsp` itself. When the interface is not carried,
  or the call is refused, fails, or gets no answer before the connection is
  lost, the write is an error shown with its message (a `refused` one with
  the daemon's) and nothing changes; the editor applies an option only from
  the state it reads back, not from its own write.
- **Buffer → project.** The LSP layer maps a buffer to its project only by
  `lw.buf_project` ([loomworks core §19.13](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md), separator-bounded), matching the record to the
  state's project by key; `lw.project_for_buf` stays public API.

**Tests.** The editor computes nothing about tests:
it does not discover them, build or run a test program, parse a test
program's output or results file, match a test to a build target, or keep
results of its own. The test tree, its states and the last results come
**only** from `view.Tests/1` (with `Tests/1` `results` for a run's
progress); discovery, runs and debug preparations are `Tests/1` calls. The
test explorer, its gutter signs and inline marks (LOOMTEST.md) are the
editor's — rendering, navigation, the cursor's test, the output window.

- **Discovery.** `Tests/1.discover` is a task ([API.md](protocol/API.md) §10.2), owned by the editor
  like an operation's ("Tasks in the task runner" above: one overseer row,
  cancellable, its one progress entry), carrying the editor's whole
  environment at call time ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Environment"). The editor sends it only
  when the view needs it: when the explorer is opened or the adapter first
  asked for the tree while the view is `stale`, on the explorer's refresh
  (`force`), and when the view turns `stale` while the explorer is open —
  never on its own otherwise, and not while the view's `discovering` names a
  running discovery (another client's included), whose `update` it waits
  for.
- **Runs.** Running a test, a suite, a target, a file's tests or all of them
  is one `Tests/1.run_cases` call (`select` the nodes' ids; run-all sends
  none; "no build" sends `no_build`), owned by the editor and shown as one
  overseer row whose output is the task's frames. The pre-run build is part
  of that task, under its locks ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Tests"): the editor builds nothing
  for a test run and the adapter's `ensure_built` is not used. While it runs
  the explorer, signs and inline marks follow `Tests/1` `results` (another
  client's runs too); its end is the view's `update`. Stopping the overseer
  row cancels the task (`Tasks/1.cancel`). Concurrent runs queue behind the
  build-directory locks ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Tests").
- **Debug.** Debugging a test is `Tests/1.prepare_debug { select }` (`select` a
  single `TestNodeRef` object, not an array; a task as
  `Launch/1.prepare_debug` is, building what a run of the node would);
  the editor hands the returned `debug` to its debugger as for a launch
  (the adapter-specific shape in the editor), and when the session ends it
  calls `Tests/1.collect { prepared }` so the daemon reads the results the
  program wrote and updates the view. The program is the editor's, never the
  daemon's. No language or adapter is assumed by the editor: they come with
  the `debug` spec, so the installed-adapter check ([loomworks core §8.9.6](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) is made after
  the task's `done` and before `debug.run()`, not before the call as for a
  launch. When the adapter is not installed the editor shows the install
  hint, starts no session and calls `Tests/1.collect { prepared }` at once,
  which drops the token and its results file (the program never ran, so it
  records nothing); a `done` without `debug` carries no token to drop.
- **Output.** The output and error locations of a node (the explorer's
  output window, the first-error jump, the inline marks and diagnostics of
  failed nodes) are read with `Tests/1.result { id }` when shown.
- **Unavailable or unloaded.** While the workspace is unloaded (the daemon
  reports it `unloaded`, or the connection is lost — "Unloaded on
  disconnect" below, the view cleared then), while it is `error` or
  `refused`, and while the feature is degraded (no host binary, an
  incompatible daemon, `loomworks.Tests/1` or `loomworks.view.Tests/1`
  missing or at another version, a daemon that offers no
  `loomworks.Tasks/1` (needed to own a discovery)), the explorer's header
  shows that status (e.g. `tests: waiting for the workspace daemon`,
  `tests: daemon offers no loomworks.view.Tests/1`), its tree is empty, and
  discovery, runs and debug are refused with that status as one notification
  line — **never** done in-process. Gutter signs and inline marks are cleared with the tree. On
  reconnect the subscription's `initial` restores the tree and the daemon's
  last results; a discovery, run or preparation the editor owned past
  `accepted` fails with the connection ("Editor operations" above) and is
  never re-run.
- **Neotest.** The neotest adapter ([loomworks core §8.9.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)) is **not available**: it discovers nothing and, the first time neotest asks
  it for anything in a session, shows one notification (`loomworks: neotest
  is not available with the workspace daemon — use the loomtest explorer`).

**Devices.** The editor neither lists nor probes devices, nor installs
or launches on them. The device list comes only from `Devices/1.list` and
its `changed` signal. A scan is a `Devices/1.scan` task carrying the
editor's environment. A device target's launch is a `Launch/1.build` call,
then `Devices/1.install` and `Devices/1.launch`, each owned by the editor
like an operation's task. Choosing a profile's device is
`Profiles/1.set_device`. Device-target launches are no longer an exception
in "Editor operations"; while the daemon cannot carry them they are refused
like any operation ("Availability"). Devices are runtime state. A reload of
the workspace keeps the device list and its ids, and doesn't cancel device
installs or launches that are running. That includes a reload caused by a
scan from a client with a different environment. An install takes the build
directory's lock and then the device's. While it waits for the device lock,
the build directory stays locked, so a build of that directory fails at once
in the meantime. A launch and a stop take only the device lock. A launched
program's log is a `Launch/1.device_log` task of the client that launched
it, which holds the device lock only while it clears the device's log; its
stream takes no lock. The editor starts it when the launch is done and shows
its records in the device-log view, through a subscription to that task's
`log` signal. Closing the view, or stopping the run, cancels the task and
drops the subscription.
Opening the view again while the run is active starts a new one. When the
task ends, the view keeps what it showed and its last line says the stream
ended.

**Tasks in the task runner.** Every daemon task the editor knows becomes
**one** task in the editor's task runner (overseer, [loomworks core §12](https://github.com/samienne/loomworks/blob/main/spec/core/integrations.md)) — one per daemon
task, not one per step: a profile build is one entry whose output carries the
`==> [build] <project>` lines; the units' states come from `meta.units`
(Running state below). A task carrying steps ([API.md](protocol/API.md) §4.3) keeps its one entry, which
follows the task's current step.

- An **editor-owned** task is a task-runner task whose start is the call,
  whose stop is `Tasks/1.cancel` ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "The editor as owner"), whose
  restart sends the call again, and whose output is the task's frames written
  to a terminal buffer, so colours and the task runner's own output actions
  (opening the output in the quickfix list) work as for a local task.
  As for Editor operations, a restart that is declined, degraded or cannot
  be carried fails the task-runner task with the reason and never runs
  in-process (the overseer task follows exactly one daemon task). A degraded restart
  still sets the Runtime-line note, as any degraded call does. The task of
  a launch's preparation (`prepare_run`, `prepare_debug`) is not sent
  again: its program is started by the editor's launch after the call,
  which a restart of the task alone would not start, so its restart fails
  the task-runner task with the reason (start the launch again from the
  editor). A device target's `Devices/1.launch` task is not restartable
  either: restarting it would start a second program on the device, which
  the editor never learns the task of and so cannot stop. A stop, or
  another restart, before a restart's call is accepted cancels the task that
  call starts; it is never shown as a task of its own. A task that ends with
  exit 0 after a cancel is a success.
- An **observed** task (another client's, `meta.origin`) is listed
  read-only, its origin marker in its name (e.g. `[lw] build dev`); stop and
  restart only say `started by lw (cli) — cancel it there`. Its output
  starts when the editor joined (Joining late below).

The editor ignores `role`: it appends each line's text, the command lines of
`verbose` included, as it appends every `line`.

No diagnostics are parsed from a task's output by loomworks, for daemon tasks
as for local ones; the quickfix list is the task runner's own action. When
the task runner cannot host such tasks (its extension point unavailable), the
editor keeps them out of its list and shows them as remote tasks only (UI
below), with a Runtime-line note. An editor-owned task has **one** progress
entry — the remote-task entry of UI below, with no origin marker — and the
editor's own progress wrapper is not shown for a routed operation; a launch's
or debug session's final phase (running, debugging) keeps its own entry.

**The observer.** Each workspace the editor loads gets an **observer**. It
watches the task streams and model changes of operations started elsewhere
(a `lw build` in a terminal). It runs none of the editor's own operations;
where those run is "Editor operations" and "Availability" above.

- **Host binary.** The observer selects the host binary it launches the
  daemon from; first match wins:
  1. **Explicit**: `LOOMWORKS_LW`, then the setup option `binary.path`. Used as
     is (no hash check: the user chose it); a relative value is made absolute
     against the editor's current directory when it is selected, so the file
     checked is the file run. A value naming no file — on Windows, no `.exe`,
     the rule of step 2 — is a note and **stops the search**: the editor never
     runs another `lw` instead of the one the user named.
  2. **`lw` on the search path**: only the search path's **absolute** entries,
     in order — never the current directory, which for the editor is a
     repository it opened, possibly untrusted ([loomworks core §17](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)); relative and empty
     entries are skipped (an absolute entry naming that directory still
     counts). On Windows the file looked for in each entry is `lw.exe` (a
     script shim cannot start the daemon detached), so an extensionless `lw`
     or an `lw.cmd` in an earlier entry neither is chosen nor hides a later
     `lw.exe`. Used when it offers the interfaces the plugin needs, as the
     pre-launch probe below decides.
  3. **The plugin-managed `lw`** under the editor's data directory: used when
     there is no system `lw`, or when it is too old (a status note says so).
     "Too old" is a **definite** failure of the probe; an unknown result is
     not a failure.

  **Pre-launch probe**. Before launching from an `lw` found on
  the search path or named explicitly, the observer runs `<binary> version
  --json` ([loomworks core §16.41](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) — asynchronously, bounded by a short timeout (about 3 s),
  with the editor's data directory as working directory (never the
  workspace) and no workspace-sourced environment — and checks the
  descriptor with the interface check of "Plugin pin" below (transport
  overlap, and the root and feature interfaces the editor uses), except that
  its schemas must **equal** the plugin's: a difference in either direction
  is a definite failure — an older `lw` cannot read the workspace files at
  the plugin's format, a newer one writes a format the editor will not
  observe, and the managed `lw` the search falls through to matches the
  plugin exactly. (An already running daemon is weighed separately at
  connect: newer schemas are refused, older ones are observed and weighed
  for a retirement under "Retiring an incompatible daemon" below; the pin
  check refuses only newer schemas.) The verdict is cached per process by the binary's path, size
  and modification time; the selection itself stays synchronous over cached
  verdicts, and while a probe runs the Runtime note says so; should the
  probe's own answer never arrive, the observer stops waiting shortly after
  the probe's timeout and goes on as for *unknown*. Verdicts:
  - **compatible** — the binary is used;
  - **incompatible** (a definite failure: no transport overlap, schemas
    older or newer than the plugin's, a missing root interface, or an `lw`
    older than [loomworks core §16.41](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md) — `version --json` succeeds but prints no descriptor:
    it predates the plugin's schemas, and a release before the daemon cannot
    run one) — a
    search-path `lw` is skipped with
    a status note naming the problems ("too old/incompatible: …") and the
    search goes on to the managed `lw`; an explicit binary is never
    replaced (rule 1), the verdict is only noted;
  - **unknown** (`version --json` exits non-zero — e.g. a host with no
    system Lua — a descriptor with no `schemas`, or a timeout) — the binary
    is used and the handshake decides.

  A missing feature interface is not a failure: that feature degrades with a
  note ("Interface client" above). The managed `lw` is not probed at run
  time: the pinned release was checked when it was pinned, and a channel
  release is checked through its published descriptor before it is
  downloaded ("Channel upgrades" below).

  The setup option `binary.prefer = "managed"` (default `"system"`) puts 3
  before 2. Its consequence: the daemon's version can then depend on who
  launched it (the CLI starts the daemon from its own `lw`, the editor from
  the managed one; [loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) decides what each does with the other's). Running a
  host binary with the plugin's or another Lua source tree (`binary.source`,
  `LOOMWORKS_LUA`, [loomworks core §16.11](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) is a development opt-in only, never automatic: it
  sets the source of the binary selected above and never selects one.

  The editor **reads no `lw.pin`**. A global or managed `lw` follows the
  repository's pin itself: the daemon commands the editor launches (`daemon
  run` and its `--stdio` relay form) are redirect commands
  ([loomworks core §16.23](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)), so they run the pinned version — unless the pinned
  release predates the command ([loomworks core §16.23](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md) "A pin older than the command"): then
  the launch is refused and the editor works without a daemon. Compatibility is
  decided after connecting, by the handshake and `Root.describe` ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md),
  [loomworks core §19.20](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)); the pre-launch `lw version --json` probe (above) is only
  a quick pre-check. It describes the binary probed, not what a redirect
  command runs in a pinned repository ([loomworks core §16.41](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)): a repository pinned to an
  incompatible release is caught by the handshake after the launch, and the
  once-per-version rule of "Retiring an incompatible daemon" keeps the editor
  from retiring that release's daemon in a loop. Only what the plugin itself
  downloads is hash-checked (against the hash the plugin release carries,
  "Plugin pin" below, or one the pinned `lw` obtained from a release's signed
  `SHA256SUMS`, "Channel upgrades" below); binaries the user
  installed (search path, explicit) get compatibility checks only. The plugin may download its managed `lw` automatically
  (`binary.download = false` turns that off): official releases only ([loomworks core §17.8](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)).

  **Plugin pin**. The plugin carries the release it downloads:
  `lua/loomworks/provision/pinned.lua`, `{ version, assets = { [<asset>]
  = <sha256> } }` with one hash per published host asset (`lw-linux-x86_64`,
  `lw-macos-arm64`, `lw-windows-x86_64.exe`; the plugin keeps its own copy of
  that table) and one for the release bundle `loomworks-lua-<version>.zip`. A
  pin without the bundle's hash wants no managed `lw`. It is never edited by hand: `scripts/release/pin.sh` writes it
  from a release's `SHA256SUMS` after verifying `SHA256SUMS.sig` with the
  committed release key, and only when the release's descriptor ([loomworks core §16.41](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md))
  offers what the editor client needs — a transport range overlapping the
  plugin's, schemas no newer than the plugin's, and `/` `loomworks.Root/1`,
  `/tasks` `loomworks.Tasks/1`, `/workspace` `loomworks.Workspace/1` (one
  check, `provision/needs.lua`). The pin is not part of the lw bundle, so the
  pin commit changes no release asset. Releases are cut in two stages: the
  build stage builds every asset of `vX` from a build commit C into an
  unpublished draft release (no tag, C recorded as its target); the cutter
  pins the draft, commits only `pinned.lua` on top of C and tags that commit
  `vX`; the tag push never rebuilds — it publishes the draft (the one draft
  named `vX`; none or several fail) only when the
  tagged commit changes nothing but `pinned.lua` since C, the pin names `X`
  and equals the draft's signed hash for every host asset and the bundle, the
  signature verifies, every host binary and the bundle of the draft are
  present and match `SHA256SUMS`, and the
  descriptor passes the interface check. Any failure, or no draft, publishes
  nothing. The cutter pushes only the tag first and pushes the pin commit to
  a branch only after the publish succeeded, so a failed gate leaves no
  branch pinning an unpublished draft. Hence a plugin checkout always pins a
  published release, never one newer than every release. Ordinary CI runs the same check on the pinned
  release as a warning only: a development checkout may need interfaces newer
  than the last release (the editor then degrades with feature notes;
  developers point `binary.path` / `LOOMWORKS_LW` at a newer `lw`).

  **The plugin-managed `lw`** lives at
  `<editor data>/loomworks/lw/<sha256>/lw` (`lw.exe` on Windows),
  content-addressed by the binary's SHA-256, so a binary is never replaced in
  place (a running daemon keeps its file). The binary the plugin wants is a
  release version, a host asset name and that asset's SHA-256: this host's
  asset of the plugin pin ("Plugin pin" above; a platform with no published
  asset, or a pin without this host's asset, wants none and the slot only says
  why), or — with `binary.channel` set — a newer compatible release of that
  channel ("Channel upgrades" below). When the selection reaches a wanted managed `lw` that is not
  installed, that decides the search: in daemon mode the observer downloads it
  — asynchronously, the editor is degraded meanwhile and the Runtime note
  says it is downloading, from where — then launches from it (or connects to a
  daemon that appeared meanwhile). The editor's data directory and
  `loomworks/` under it may be links (followed); `loomworks/lw/` and the slots
  are created as, and must be, real directories. The download goes into a
  temporary file `<sha256>.<pid>.<n>.dl` next to the slots (unique per
  process and attempt); whatever is at that path first (a stale file, a link)
  is unlinked, never written through. Its SHA-256 must equal the wanted one,
  then it is made executable (POSIX) and renamed into its slot (on Windows
  the rename is retried briefly while the new file is held, e.g. by an
  antivirus scan). A failure (network, missing asset, hash mismatch) removes
  the temporary file, installs nothing and is one note naming the binary and
  why (running degraded); it is not retried until `:LoomworksDaemon
  connect`. Requests for one hash share one download; a slot another editor
  filled meanwhile is kept. `:LoomworksDaemon connect` while a download runs
  aborts it (curl is stopped, the temporary file removed) and starts over;
  unloading the workspace aborts it. A transfer is bounded: a connection
  must come up within 20 s, one slower than 1 KiB/s for 30 s is dropped, none
  runs past 300 s (three attempts, lw's retry rule).
  A managed binary is present only as a regular file (lstat: a link in a slot
  is never launched) whose SHA-256 matches its slot's name; the editor hashes
  it once per process before first using it. One that does not match is
  corrupt: never launched, one note, and in daemon mode downloaded again and
  renamed over it.

  **The managed bundle.** A release host carries no system Lua ([loomworks core §16.22](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)), so
  the managed `lw` is a pair: the host binary above and the bundle
  `loomworks-lua-<version>.zip` of the same release, hashed by the same pin or
  channel result. The bundle lives at
  `<editor data>/loomworks/bundle/<sha256>/lua-<version>/`, `<sha256>` being
  the zip's SHA-256: exactly the zip's entries, written once, never modified.
  Every process the editor starts from the managed binary (relay, the daemon
  it launches, the channel query, a retirement's relaunch) gets
  `LOOMWORKS_INSTALL_DIR=<editor data>/loomworks/bundle/<sha256>`, so `lw`
  runs that bundle as a release source ([loomworks core §16.22](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) and still follows a
  repository pin ([loomworks core §16.23](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)); never `LOOMWORKS_LUA` (a development source
  bypasses the pin). `lw` may write there what its install folder holds
  besides bundles (`release-notes-seen`, the pin redirect's `pinned/`); the
  plugin never runs `lw self-update` with it. A search-path or explicit `lw`
  gets no install-folder override.

  When the managed `lw` is wanted and its bundle slot is absent, the zip is
  downloaded with the binary's source, transfer bounds and `binary.download`
  switch into `<sha256>.<pid>.<n>.dl` in `loomworks/bundle/`, and its SHA-256
  must equal the wanted one. The plugin reads it itself (no external tool).
  Nothing is installed unless every entry:
  - is a regular file or directory (no link, no other type) under
    `loomworks/`;
  - has a name of `/`-separated segments, none empty, `.` or `..`, with no
    leading `/`, no `\`, `:` or NUL;
  - has a name no other entry repeats case-insensitively;
  - matches its CRC-32.

  Entries are written as newly created regular files (never through an
  existing file or link) into
  `loomworks/bundle/.stage-<sha256>.<pid>.<n>/lua-<version>/`, created by an
  exclusive mkdir. The staging directory is then renamed to
  `loomworks/bundle/<sha256>` (on Windows retried briefly). The rename never
  replaces a non-empty directory: a slot another editor installed meanwhile
  is used. Requests for one hash share one provisioning. A failure installs
  nothing and is one note (running degraded), not retried until
  `:LoomworksDaemon connect`. The temporary file is removed, and the editor
  removes its own staging directory: only that exact path, a real directory
  under `loomworks/bundle/`, with links inside unlinked, never followed.

  `loomworks/bundle/` and its slots are created as, and must be, real
  directories. A slot is present only when `<sha256>` and `lua-<version>` are
  real directories (lstat) and `lua-<version>/loomworks/cli.lua` is a regular
  file. It is then used by presence: it is only ever populated by the rename
  after verification, as for `lw`'s pinned bundles ([loomworks core §16.24](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)). Any other state
  at that path is never used, never repaired or removed automatically, and
  makes the managed source absent with one note naming it.

  The source is `<base>/<asset>` for a release-source override (the
  setup option `binary.release_url`, else `LOOMWORKS_RELEASE_URL`: a local
  directory, `file://` or a flat mirror, as for `lw`, [loomworks core §16.29](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)), else `lw`'s
  fixed origin's `releases/download/v<version>/<asset>`; http(s) goes through
  `curl` from the search path's absolute entries; from an https source a
  redirect may lead only to https (`--proto-redir =https`; a configured http
  mirror is used as given). The hash, not the transport, is the trust anchor. `binary.download = false` turns downloads off (the
  managed source is then absent, with why); `:checkhealth` never downloads,
  it reports what would be downloaded and the state of a download.
  Each slot's directory mtime is its last use: set when the slot is created
  or installed into, and whenever an editor selects the binary (marked at
  most once an hour) or connects to a daemon whose handle names it.
  Pruning of managed binaries and bundles is paused (samienne/loomworks#101):
  the editor removes no slot in `loomworks/lw/` or `loomworks/bundle/`, and
  nothing another process left there; it removes only its own temporary file
  and staging directory of a failed attempt. Slot directory mtimes (binary and
  bundle slots) still record last use for that future pruning. A search-path or explicit `lw` is probed before
  the launch ("Pre-launch probe" above); the managed `lw` is not.

  **Channel upgrades**. The setup option `binary.channel`
  (`"stable"` or `"unstable"`; default unset = the plugin pin only, no
  channel lookups) lets the managed `lw` move ahead of the pin. It applies
  only when the selection reaches the managed source, `binary.download` is
  not `false`, `binary.source` is not set (a development binary is never
  channel-resolved) and the runtime mode is daemon. In the background, at most
  once a day and on `:LoomworksDaemon connect`:
  1. The **pinned** managed `lw` is made present and verified first (the
     download above). Only that binary resolves a channel — never an `lw`
     from the search path or an explicit one, which are the user's to update.
  2. It runs `<pinned lw> release query --channel <channel> --json` ([loomworks core §16.42](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md))
     with the release-source override (`binary.release_url`) and the
     install-folder override of "Install location" passed through, the
     editor's data directory as working directory, and bounded fetch limits.
     The output must name a valid release version, this host's asset and
     `loomworks-lua-<version>.zip`, each with a 64-hex hash, and carry the release's descriptor; that descriptor must
     pass the interface check of "Plugin pin", with the pre-launch probe's
     schema rule (schemas **equal** to the plugin's: the managed `lw` is what
     the search falls through to, and a daemon with older schemas would be
     weighed for a retirement).
  3. A result that passes and names a version newer than the current wanted
     one ([loomworks core §16.29](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md) ordering: a pre-release ranks below its release) is
     **accepted**: it becomes the wanted binary and bundle, both provisioned as
     above, each hash-checked against the query's hash. It is recorded as
     accepted only once both succeeded; a failed download is one note and
     the current wanted binary stays. A running daemon is not
     switched while it is busy: its code identity now differs from the
     wanted binary's, so the editor retires it once it is idle ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)
     "Editor retirement") and the next launch uses the new binary; the
     Runtime note says so.
  4. A result that fails the check is one note ("<channel> offers lw <v>,
     which this plugin cannot use (…); staying on <v'>") and is recorded so
     the same release is not checked again.

  The wanted binary is the newer of the pin and the last accepted channel
  result, so it never goes below the pin. The last result is kept in the
  plugin's own file `<editor data>/loomworks/channel.json` (outside
  `loomworks/lw/`, written atomically, never pruned); changing
  `binary.channel` invalidates it. Switching from `unstable` to `stable`
  keeps a newer accepted pre-release until stable overtakes it (as for lw's
  own bundles, [loomworks core §16.29](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)); unsetting `binary.channel` returns to the pin. A
  query result older than the accepted one (a withdrawn release) is ignored.
  Offline, a bad signature, a tampered descriptor or a pinned `lw` older than
  the query command are one note each; the editor keeps the current wanted
  binary, downloads nothing and retries only at the next interval or an
  explicit connect. A release-source override supersedes the channel; the
  query reports that and the editor notes it ([loomworks core §16.29](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md): never silent).
  `:checkhealth loomworks` reports the last check and never queries. When a
  search-path `lw` is selected, `binary.channel` has no effect and the status
  note says why (`binary.prefer = "managed"` changes that).

  **Retiring an incompatible daemon** ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Editor
  retirement"). On connect, a daemon is **incompatible** with the editor
  when its transport range does not overlap the editor's (detected at the
  handshake; `ping`, `status` and `retire` are version-stable, loomworks spec [PROTOCOL.md §7](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md), so the
  editor can still authenticate and retire it), when it does not offer
  `loomworks.Root/1`, or when its schemas are older than the editor's (it
  cannot read the editor's files). The `loomworks.Root/1` requirement applies
  only to a transport (protocol) 11 connection whose welcome lists the
  daemon's interfaces (`welcome.objects`); a protocol-10 daemon offers no
  interfaces and is judged by its version and schemas only. A missing
  feature interface only degrades that feature ("Interface client") and is
  never a reason to retire. The
  editor sends `retire` (never `stop`) to an incompatible daemon, or to a
  compatible one whose code identity differs from the relay's
  (`welcome.relay`) ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Editor retirement"), only when all of these hold:
  - the daemon is idle (no busy client, [loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Busy") — the editor's own
    connection included: a task the editor owns makes it busy,
    so the editor never retires a daemon under its own running tasks (and it
    routes nothing to a daemon it found incompatible, "Editor operations"
    above);
  - its schemas are not newer than the editor's;
  - the binary the editor selected passed the interface check (the probe's
    *compatible* verdict, or the managed `lw`);
  - the binary that would start in its place has another code
    identity (`lw_version`, [loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)) than the daemon: for a compatible
    daemon the relay's (`welcome.relay`, which must be present), for
    an incompatible one the selected binary's;
  - the editor has not already retired a daemon of that identity for this
    workspace in this editor session.

  Then the "Retiring" path below relaunches once. A busy incompatible daemon
  is a note ("incompatible daemon is busy; retiring when idle") and is
  re-checked through `status` about every 30 s. When the once-per-version
  rule stops the retirement of an incompatible daemon — the successor runs
  the same version again, typically because a repository pin redirects to
  it — the note says so (the daemon runs lw <v> again, likely a repository
  pin; update the pin or the plugin); when that earlier retirement failed (below), the note says
  instead that retiring a daemon of that version failed earlier this
  session, and it is not tried again. A compatible daemon stays observed
  throughout, with no note: busy, it is re-checked the same way and retired
  once idle; declined, it stays observed. Only a failed retirement of it is
  noted on the Runtime line.

  A daemon whose only incompatibility is older schemas (transports overlap,
  root interface present) is observed as usual ("Connect" below) while the
  editor weighs it — while the selected binary is probed, while the daemon
  is busy — and for the rest of the session when the editor declines to
  retire it; the Runtime line says why. Any other incompatible daemon is not
  observed: the editor holds its connection only to ask `status` and send
  `retire`, ignores anything else it sends, and closes it when it declines.
  While a `status` is unanswered no other is sent; a `status` still
  unanswered at the next re-check ends the wait: the daemon is neither
  retired nor relaunched, the Runtime line says it stopped answering, a held
  connection is closed and an observed daemon stays observed (its keepalive
  notices one that is gone). `retire` is sent at most once. An error reply
  to `retire`, or none within one re-check interval, is a failure: the
  Runtime line says so, nothing is relaunched, an observed daemon stays
  observed, and the once-per-version rule still counts the attempt (as a
  failed one). The connection closing
  instead of a reply counts as retired. Tasks of an observed daemon end when
  its connection closes, as for any drop. While the editor asks a daemon
  that reports no `busy_clients` ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "Busy"), its own observer connection
  is counted among the observers, not subtracted again.

  **Install location.** Everything the plugin installs (host binaries in
  `loomworks/lw/`, release bundles in `loomworks/bundle/`, and what a managed
  `lw` downloads for itself, the pin redirect's binaries and bundles, through
  its install-folder override `LOOMWORKS_INSTALL_DIR`, which is its bundle
  slot, [loomworks core §16.22](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) stays under the
  editor's data directory (`<editor data>/loomworks/`) — except the bundle
  copy a pinned release older than the install folder provisions for itself,
  which lands in `lw`'s per-user data directory ([loomworks core §16.22](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)). The plugin never installs a system-wide `lw`
  and never writes configuration into the user's home. Shared runtime state
  stays where `lw` keeps it, for every `lw` on the machine: daemon sockets and
  identity, the trust store ([loomworks core §17.2](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)), daemon logs. The plugin reads `lw`'s
  per-user configuration (its settings, [loomworks core §19.1](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)) and writes it only on an
  explicit user action.

  With none, the status page shows one inline note naming each source and
  why it gave nothing (no host binary: running degraded); while the
  observer launches, its note names the binary and its source.
  `:LoomworksDaemon status` and `:checkhealth loomworks` list every source
  with its verdict. The editor never launches a daemon from its own plugin
source unless `binary.source` asks for it. It follows daemons only through
relays, which need a host binary, so with none it spawns no relay, runs
degraded, and does not observe a daemon another client started ("End
state").
- **Launch.** The editor launches no daemon itself and starts no child
  daemon: an ordinary relay launches the daemon when none is live, on the
  occasions "Through the relay" above lists, and a relay that exits before
  `welcome` is handled under "Exit before `welcome`".
- **Connect.** The relay handshakes for the editor as `client = "editor"`,
  `role = "observer"`. An observer may start and own operations
  ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "The editor as owner"); there is no separate role. The
  editor judges `welcome.daemon`: it observes a daemon whose transport range
  overlaps its own and whose schemas are not newer ([loomworks core §19.9](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md);
  the host version may differ). A `welcome` without `via` is observed
  without this check ("Through the relay" above).
  - **Incompatible daemon.** A daemon with older schemas (and nothing else
    wrong) is observed; any other incompatible daemon (no transport overlap,
    newer schemas, or, over transport 11, a missing root interface) the
    observer notes and does not observe, and does not connect to it again;
    through the relay it follows a successor with `--no-launch
    --skip-instance` ("Skipping an incompatible daemon" above). It never
    restarts an incompatible daemon; it retires it only under "Retiring an
    incompatible daemon" above, which also says how long an older-schema
    daemon stays observed.
  - **Keepalive.** While connected it sends `ping` about every 30 s.
- **No relaunch after a stop.** When the connection drops because the daemon
  stopped (`lw daemon stop`), crashed or dropped this observer, the editor
  never launches a daemon by itself; this keeps `lw daemon stop`
  meaningful. It follows the daemon as "Following a stopped or retiring
  daemon without relaunching it" and "Skipping an incompatible daemon" under
  "Through the relay" above say: a `--no-launch` relay, with
  `--skip-instance` for an incompatible daemon. The editor keeps no list of
  skipped daemons of its own.
- **Loaded on attach.** When an editor connects (`role =
  "observer"`), the daemon, after its `welcome`, starts loading the
  workspace unless it is loaded or a load is under way — as a `snapshot`
  loads it, in the daemon's own environment and without waiting for tool
  detection — so an editor-only session does not stay `unloaded`. A
  connection without that role (the CLI) never starts a load, and
  `LspConfig/1.get` still never loads. Because this load uses the daemon's
  own environment, a later operation from a client whose environment
  differs reloads the workspace first ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)).
- **Unloaded on disconnect.** When a connection the editor
  held is lost, for any reason (the daemon stopped, crashed, retired or
  dropped this client, the relay ended), the editor's workspace is
  **unloaded** until a reconnect's daemon reports it
  `loaded` again — as if the daemon had answered `unloaded`: nothing of the
  daemon's runs for it. Its remote tasks end ("Tasks" below), an operation
  past `accepted` fails ("Editor operations" above), and the controlled
  language servers under the root are stopped and their buffers held
  ("LSP configuration" above); the tests view is cleared and the explorer
  shows the status ("Tests" above). Programs the editor launched (in its task
  runner) and debug sessions are not stopped. The Runtime line says so in the warning
  highlight (`the workspace daemon disconnected — workspace unloaded,
  waiting for it`, UI §1.1) until the daemon reports `loaded`. A
  workspace swap or shutdown is not a lost connection ("Teardown" below).
- **Retiring.** On `retiring` (broadcast, or in `welcome`) the observer
  disconnects at once, so a version change completes ([loomworks core §19.11](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)).
  It then follows the daemon as "Following a stopped or retiring daemon
  without relaunching it" under "Through the relay" above says: the wait
  happens in a relay (`RELAY_RETIRE_WAIT`, or `--no-launch`, with
  `--retiring` when the instance is known, ending in exit 16), and the one
  launch per retirement episode is an ordinary relay's.
- **Model changes.** On `model_change` the editor applies its files' pending
  changes at once (loomworks spec [PROTOCOL.md §12–§13](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md)).
- **Tasks.** Each observed task becomes a **remote task** in the editor.
  - **Resolving.** Its `start` meta is resolved at the boundary. The profile
    key is looked up among the workspace's profiles. Each unit is matched to
    that profile's project-in-profile with the same project key and
    configuration-unit key, and through it to its configuration unit. A key
    that does not resolve (another working copy, a profile the editor has not
    loaded yet) is kept and shown **by name only**; no domain object is
    created or hydrated for it.
  - **Running state.** A remote task puts the same runtime state on the
    editor's objects as a local operation of its `kind` would ([loomworks core §3](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)): each
    resolved configuration unit reports `building` (or the kind's state), so
    its build directory shows it too, and the resolved profile counts as
    having an active operation (UI §1.5). A remote `clean` shows its
    units `cleaning`, the display of the transient clean state ([loomworks core §3.1](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md), transition rule 5),
    without changing their cached state; a remote `test` or `run` shows
    `building`. A remote `reset` shows its units
    `deleting`, the display of the transient deletion state ([loomworks core §3.1](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md), transition
    rule 5) of the in-process reset, whose deletion is not a clean. A
    `reset --all` has no profile (`meta.scope = "all"`, [loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) Reset): its
    units are resolved by project key and configuration-unit key among the
    workspace's configuration units, and every profile with a resolved unit
    counts as having an active operation. The state is runtime-only:
    the editor never writes the cache or the working copy for a remote task
    and runs nothing. It never blocks an editor operation: the cross-process
    build-directory locks ([loomworks core §16.6](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) do.
  - **Joining late.** On each connect the observer sends `status` and adopts
    every task in its `tasks` ([loomworks core §19.11](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)) as a remote task, its output starting
    from that moment; a task already ended is never shown. `status.tasks`
    carries no steps (frozen, [loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)): when it adopted a task and is
    subscribed to `/tasks`, the observer reads `Tasks/1.list` once and adopts
    the steps and current states it gives ([API.md](protocol/API.md) §4.3); later
    `step` signals are deltas on top of them. `/tasks` signals that arrive
    before the subscribe reply are held, then applied only past its `seq`
    baseline (loomworks spec [PROTOCOL.md §12–§13](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md)).
  - **Output.** The task's lines and output are kept, capped at about 1 MiB
    per task, then one truncation notice.
  - **End.** A task ends on `done` (success, failure or cancellation), or
    when the connection drops (it is then shown as ended "the workspace
    daemon disconnected"). Either way its runtime state is cleared at once;
    the unit's state after the task is whatever the editor's files then say.
    The daemon sends the `model_change` of the task's cache write-back
    (loomworks spec [PROTOCOL.md §12–§13](https://github.com/samienne/loomworks/blob/main/spec/protocol/PROTOCOL.md)) before its `done`, so the editor has already reloaded the
    outcome when the running state clears.
  - **UI.** A remote task is shown exactly as a local task of the same kind
    and profile: in progress (fidget, the same entry and end message — for
    a `clean`, `cleaned` / `clean failed`, as a local clean's; for a
    `reset`, which has no local editor task, `Resetting` and `reset` /
    `reset failed`, with the profile's name or `--all`), in the
    status page's Profiles and Tasks sections (UI §1.5, §1.9), and
    in the status line. It is neither cancelled nor restarted from the editor
    ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)). Its only difference is an **origin marker** naming who started
    it, from `meta.origin` ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)). It is also listed
    read-only in the task runner's task list, and a task the editor itself
    started through a call is shown the same way without an origin marker,
    cancelled and restarted from the editor ("Tasks in the task runner"
    above).
- **Teardown.** Unloading or swapping the workspace stops its observer: the
  timers stop, the connection closes, remote tasks are cleared. The daemon
  keeps running ([loomworks core §19.11](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md)); the close cancels the tasks the editor
  owns ([loomworks core §19.15](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md) "The editor as owner"), and their operations end as
  failed in the editor. The connection closes by closing the relay's
  standard input, and a waiting relay is ended the same way, never by a
  process-tree kill ("The relay process" under "Through the relay" above).
- **Quiet degradation.** Every problem is the observer's one current note,
  shown on the status page's Runtime line, never a notification or a repeated
  message.

A version mismatch the editor cannot repair by restarting (its plugin code and
the resolved binary differ in protocol or schemas) is shown inline. The editor
runs degraded. The note is never silent: it stays on the Runtime
line (warning highlight) for as long as the mismatch lasts, naming both sides'
protocol (or schema) and versions, the binary's path when known (the
daemon's handle `exe`, [loomworks core §19.6](https://github.com/samienne/loomworks/blob/main/spec/core/daemon.md), whoever started it; an older daemon's handle may
not name one), and the remedy (update
the plugin, or pin or install a matching lw), e.g. `Runtime:   daemon
(default) — lw v0.1.44 (protocol 7) does not match this plugin (protocol 6):
update the plugin or the pin — running degraded`.
From protocol 11 this whole-daemon note applies only to a transport mismatch;
a missing interface version is the per-feature note of "Interface client".


# Part II: UI

# UI

Status page, highlight groups, and the winbar/statusline component.
Section numbers in this file are local. Cross-refs to core sections
use `core §X.Y` form.

---

## 1. Status page

### 1.1 Layout

The status page opens as a floating window (default 100 columns, 90%
editor height). Window position and size can be configured via `setup()`
options or overridden per `open()` call — the `win` table is passed
directly to `Snacks.win`. The page contains these sections in order:

1. **Header** — plugin version (the running loomworks version, resolved
   like `_meta.written_by`, §2; `dev` when unknown), workspace name,
   workspace root
2. **Diagnostics** — aggregated structural diagnostics (hidden when empty)
3. **Suggestions** — a single compact line, `N suggestion(s) — run \`lw
   health\``, shown only when the suggestion framework has one or more
   **actionable** items (hidden when none). `N` counts actionable items only
   — informational items (e.g. the affirmative "Compiler cache: using
   `<tool>`") appear in `lw health` but never in the count, so a healthy
   workspace shows no line. Rendered with the `LoomworksStale` highlight
   (hint-level, like the `[stale — reconfigure]` hints: advisory, not a
   warning). It is advisory, not a diagnostic: unlike the
   Diagnostics section, suggestions never gate an operation and never fail
   `--check`. A **missing required** environment-inventory item recorded by a
   prior `lw health` ([loomworks core §16.33](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)) counts like any actionable item; the page
   never probes the environment itself. The line's detail lives in `lw health` ([loomworks core §16.31](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)); the
   status page keeps only the count so the page stays uncluttered. The
   first-shipping provider flags a workspace that has C/C++ projects but no
   compiler cache on the toolchain path (see §16.31).
4. **Profiles** — all materialized and explicit profiles
5. **Orphaned Configurations** — unreferenced cached configs (hidden when empty)
6. **Configuration Sets** — declared sets with tool entries
7. **Projects** — all projects with their configurations
8. **Tasks** — active loomworks-managed tasks and held build-dir locks
   (hidden when both empty). Placed at the bottom because it's the
   runtime-state diagnostic surface — only interesting when something
   is wrong.

Sections are separated by blank lines. Each section has a title line.

### 1.2 Tree Structure

The status page uses a foldable tree widget with two-level nesting.

**Node types**:
- `leaf` — plain text line, no interaction. Accepts either `(text, hl)` or
  a list of `{text, hl}` chunks for mixed highlights on one line.
- `node` — foldable line with children, opened with `l` and closed with `h`
- `item` — interactive line with actions, no folding
- `group` — labeled sub-section that increases indentation. Accepts either
  `(label, hl, children_fn)` or `(chunks, children_fn)` for mixed highlights.
- `blank` — empty line for spacing

**Fold characters**: `▶` (folded), `▼` (unfolded)

**Spinner**: Braille animation (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) at 80ms interval,
shown when `spinning = true`. Replaces the status marker for running items.

**Status markers**:
| Status           | Marker |
|------------------|--------|
| unconfigured     | ○      |
| configured       | ◆      |
| built            | ✔      |
| configure_failed | ✘      |
| build_failed     | ✘      |
| running/deleting | (spinner) |

### 1.3 Keybindings

| Key     | Action      | Behavior |
|---------|-------------|----------|
| `<Tab>` | next_item   | Move the cursor to the next interactive line |
| `<S-Tab>` | prev_item | Move the cursor to the previous interactive line |
| `l`     | open_fold   | Open the fold on the current node |
| `h`     | close_fold  | Close the fold on the current node |
| `<CR>`  | enter       | Open action picker on nearest actionable node |
| `b`     | build       | Build (walks up to nearest node with `on_build`) |
| `<C-b>` | build_serial | Build serially (`-j1`), for readable error output (walks up like `b`) |
| `c`     | configure   | Configure (walks up to nearest node with `on_configure`) |
| `o`     | options     | Show build options float (on configured project nodes) |
| `t`     | task        | Open overseer task output for nearest config (float) |
| `R`     | rebuild     | Clean + build (destructive, with confirmation) |
| `C`     | clean       | Run module clean tasks, reset to configured (with confirmation) |
| `D`     | delete      | Delete profile or configuration (destructive, with confirmation) |
| `N`     | create_workspace | Refused, naming `lw init` (core §13.5); nothing written |
| `L`     | load        | Load workspace from cwd / rescan tools |
| `<C-n>` | nuke        | Reset workspace: delete `.nvim/build/` + cache, reload (destructive, with confirmation) |
| `P`     | publish     | Cycle intent (`local` → `local+shared` → `shared`) on nearest publishable item |
| `e`     | describe    | Edit the description ([loomworks core §1.10](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) of the nearest describable item — profile, configuration set, project, or user configuration — in the description editor (§1.16) |
| `K`     | hover       | Hover popup with the full content of the current line; a row may supply its own hover content (on a describable item, its full description, §1.16) |
| `U`     | delete_user | Delete user.json and reload (with confirmation); for a refused working copy ([loomworks core §17.4](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)) this is the discard action |
| `T`     | trust       | Refused working copy ([loomworks core §17.4](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)): review its summary and trust (re-sign) it |
| `:w`    | (write)     | Publish: regenerate loomworks.json from working copy |
| `:e`    | (edit)      | Reload from published baseline (refused if any divergence) |
| `:e!`   | (force edit)| Force-revert workspace to baseline (preserves data, drops publication wishes for unmatched items) |
| `?`     | help        | Show help dialog |
| `q`     | (close)     | Close the status page |

**Action dispatch**: For `build`, `build_serial`, `configure`, `rebuild`, `clean`,
`delete`, `options`, and `describe`, the tree walks upward from the cursor line to find the
nearest node that has the corresponding `on_<action>` callback. This means pressing
`b` on a child detail line triggers the build action of the parent node.

**Action picker (`<CR>`)**: The Enter key walks up to the nearest widget with
`on_*` callbacks, collects all available actions, and opens `vim.ui.select`
with the action list. The `enter` action label is context-dependent, set by
the section renderer via the `enter_label` field on the widget:
- Profile nodes: "Activate"
(`describe` also appears in every describable node's action list as
"Edit description", so it is discoverable without knowing `e`.)
- Config set tool entries: "Activate"
- Project config/tool nodes: "Open task output"

The picker is skipped (direct invoke) when:
- The widget has `direct = true` (sentinel lines), OR
- Only one action exists on the widget (no other actions to discover)

**Sentinel lines**: Interactive `item` nodes that appear at the end of
sections to provide discoverable create/add flows. Sentinels have
`direct = true` on the widget, so Enter invokes `on_enter` immediately.
- **Profiles section**: `▸ Create new profile` — opens the profile creation
  multi-step picker (config set → tool → materialize). Shows "No projects
  yet." when no projects exist.
- **Projects section**: `▸ Add project` — opens the project browser float.

**Destructive action highlighting**: `R`, `C`, `D`, `U`, `<C-n>` keys are
highlighted with `DiagnosticWarn` in the help dialog.

### 1.4 Action Hints

Action hints show available keys close to the actionable items. Hints use
`Comment` highlight. Format: `[key] label  [key] label  ...` — keys in
brackets, separated by double spaces.

**Header hint**: After the Root line, a `Comment` leaf shows global actions:
`[?] help  [L] load  [<C-n>] reset`

**Refused-state hint**: When the workspace failed to load because a `.nvim`
file was refused ([loomworks core §17.4](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)), the page shows only the load error (title,
`Failed to load workspace`, root, message) followed by a blank line and a
`Comment` hint naming the remedy for the refused file:
- refused working copy (`user.json`): `[T] review & trust  [U] discard working copy`
- refused build cache: `[<C-n>] reset build cache`

**Group header hints with `[t]`**: Profile project groups also include `[t] task output`.

**Section title hints**: Some sections show a `Comment` hint line after the
title listing available actions for top-level nodes.

| Section | Hint line |
|---------|-----------|
| Profiles | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Orphaned Configurations | `[D] delete` (appended to title via chunks) |

**Group header hints**: Inner groups that contain actionable items append a
hint suffix to the group label. The label uses `LoomworksActionable` highlight
and the suffix uses `Comment` highlight (via `group` with chunks).

| Group label | Section | Hint suffix |
|-------------|---------|-------------|
| Projects: | Profiles | `[b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Tools: | Configuration Sets | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Configurations: | Projects | `[b] build  [c] configure  [o] options  [R] rebuild  [C] clean  [D] delete` |

### 1.5 Profiles Section

Shows all materialized (cached) and explicit profiles. Profiles only appear
here when they exist in the cache or are declared in the config.

**Profile node display** (all profiles use the same rendering):
```
{marker} {fold_char} {profile_key} [{tag}] ({status_label}) [{elapsed}] [— {op_message}]  {summary}
```

Where:
- `{tag}` = `[stale]` for orphaned profiles, `[explicit]` for declared
  profiles, omitted otherwise. A profile that shares an output artifact with
  another profile (its resolved artifact set overlaps — see [loomworks core §5.9](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)) additionally carries a `[conflict]` tag, highlighted
  `LoomworksConflict`. The tag is absent while a profile is unconfigured, since
  artifacts are unknown until configure ([loomworks core §5.9](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)).
- `{status_label}` = aggregate status from `Profile:status()` (e.g., "built",
  "1 configuring, 1 failed build", "3 configured, 2 unconfigured")
- `{elapsed}` = shown only when running (e.g., "1m23s")
- `{op_message}` = last operation result (e.g., "built in 42s")
- `{summary}` = the profile's description summary (§1.16), fitted to the
  remaining width; omitted when the profile has none

All profiles are displayed identically. A profile with key `"Debug:ninja-gcc"`
appears like any other profile; it simply has fewer projects when expanded.

**Profile highlight rules**:
| Condition | Highlight |
|-----------|-----------|
| Has active Operation + active | `LoomworksActive` |
| Has active Operation + not active | `LoomworksRunning` |
| Active (no operation) | `LoomworksActive` |
| Failed status | `LoomworksFailed` |
| Unconfigured | `LoomworksUnconfigured` |
| Otherwise | `LoomworksConfigured` |

Note: "Has active Operation" means this profile initiated the action.
Profiles that share ConfigUnits with the initiating profile show spinners
(from running ConfigUnit state) but not the orange highlight or timer.

**Cancel action** (added to the Enter picker when `profile:is_running()`):

The action picker on a running profile includes `Cancel running task(s)`.
On select, every unit mapped by the profile's config_set with an active
task_id has its task stopped via `Workspace:cancel_tasks_for_profile`.
Tasks chained behind a cancelled one (e.g. the build link after a
configure) auto-abort because the Future token in `start_one_task` bails
their `do_start` before the next launch. A notification reports the
count cancelled. The same picker entry appears on per-configuration
rows for fine-grained single-task cancel. Cancel is not exposed as a
direct hotkey — only through the picker — because the destructive
scope (profile-level) benefits from the explicit pick.

**Profile children** (when unfolded):
- Description (only when the profile has one) — the full description,
  rendered per §1.16, as the first child
- Set name (with warning if orphaned/stale) — only for set-based profiles
- Toolchain — a single profile-level row. A toolchain is one decision
  (host tools or an SDK kit identity `(sdk, platform, arch)`) shared
  across every tool-needing module in the profile. Row format
  `Toolchain: <label>`. Label resolution: for SDK kits the canonical
  shape is `<platform> <version> <arch>` (e.g. `Android 14
  arm64-v8a`); for host selections it's `<tool_label> [host/<mod_id>]`
  per module; otherwise `(none — incomplete)`. `<CR>` opens the
  unified picker — entries are host tools from each tool-needing
  module's registry plus one entry per kit from each resolved SDK
  (sourced from `SDK:kits()`), with a `(none)` sentinel.
  Picking an SDK kit calls each tool-needing module's `kits_from_sdk`
  with the chosen `(sdk, platform, arch)`, matches by the kit's
  composite `id`/`kit_id`, and stores the per-module tool_data
  atomically. Host picks set only the target module's `_tools_raw`
  entry and clear the SDK.
- Compiler cache — a single profile-level row, sibling to the Toolchain
  row, shown for a profile that contains a C/C++-caching module. Format
  `Cache: <tool>` naming the resolved launcher (`ccache` / `sccache`), or
  `Cache: off` when the effective `cache` policy ([loomworks core §1.3.2](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) is `off`, or
  `Cache: auto (none found)` when policy is `auto` but no
  launcher is present on the toolchain path, or `Cache: <policy> (not found)`
  (e.g. `Cache: ccache (not found)`) when the policy names a launcher
  explicitly but it is not present — the build then runs uncached, and
  `lw health` reports it as an actionable item — or `Cache: auto (off for MSVC-style)`
  when policy is `auto` on an MSVC-style compiler, which never enables a
  launcher automatically ([loomworks core §1.3.2](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) — the headless row adds a pointer to
  `lw help cache`, which explains how to opt in — or `Cache: not applied (<reason>)` when the policy is not `off` but
  the module cannot apply a launcher to the profile's configuration at all
  ([loomworks core §8](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md) `cache_launcher_applicable`, with the module's reason, e.g.
  `not applied (preset)` or `not applied (Visual Studio 17 2022 generator)`);
  the row then never names a launcher the build does not use. The row is informational only in v1 (no picker); the policy is
  edited through the variable
  system. When the launcher currently resolved differs from the one the
  profile's configured units were built with (§8.1 `compiler_cache`
  staleness, [loomworks core §5.1](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)), the row carries a `[stale — reconfigure]` hint
  (highlight `LoomworksStale`) meaning the next build reconfigures to apply
  the change. The per-configuration cache mismatch also surfaces as the same
  `[stale — reconfigure]` hint on the affected project row under the profile
  (alongside the `(status)` suffix), so the user sees which configs will
  reconfigure.
- Default target, shown as `Target: <project>:<name>`, or `(stale)`, or
  `(no target set)`. `<CR>` opens the Build / Switch target picker. For a
  launch configuration, the row appends its description summary (§1.16).
- Device selection (only when the profile contains a project from a
  device-capable module) — shows `Device: <name> (<serial>)` (online),
  `Device: <serial> (offline)` (offline/stale), or
  `Device: (none selected)`. `<CR>` opens device picker.
- (The last-operation message is shown in the profile header line via
  the `— <message>` suffix, not repeated here.)
- Projects sub-group:
  - Each project: `project_key [module_type] → variant (status) {progress} {overwritten_tag}`
    with status highlight. The `(status)` suffix mirrors the profile
    header's `(status)` so the expansion doesn't need a separate
    `Status:` leaf. `{overwritten_tag}` = `[overwritten]` (highlight
    `LoomworksConflict`) when this config unit was built but another unit's
    build has since overwritten its shared output artifact ([loomworks core §5.9](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)) — the built marker (✔) is retained, the tag signals the on-disk
    artifact is no longer this unit's. Same category as the `!` refresh tag
    (§1.8): the unit needs a rebuild to reclaim its output.
  - When unfolded: build dir and targets only. Tool / generator /
    compiler leaves are dropped — the toolchain is shown once per
    profile in the profile-level Toolchain row, not repeated per
    config.

**Profile actions**:

| Node type | `<CR>` | `b` | `c` | `t` | `R` | `C` | `D` |
|-----------|--------|-----|-----|-----|-----|-----|-----|
| Profile | activate | build all | configure all | — | clean+build all | clean all | delete with dialog |
| Project under profile | open task output | build config | configure config | open task output | clean+build config | clean config | delete config with dialog |

**Sentinel: Create new profile**

After the profile list (or as sole content when empty), an interactive item:
```
▸ Create new profile
```
Enter opens the profile creation multi-step picker:

1. **Pick configuration set**: Shows existing config sets from the
   workspace config, plus auto-detected options from
   `generate_default_config_sets()`. Auto-detected options are labeled
   `"Name (auto-detected)"` with a mapping summary. Selecting an
   auto-detected option writes it to user.json via
   `add_configuration_set()` before continuing.

2. **Pick tool** (skipped if module has no keyed tools, or only one tool
   detected): Shows available tools from `detect_tools()`.

3. **Materialize**: Calls `config_set:ensure_profile(tool_entry)` to
   create the profile in cache. Auto-activates only when this is the
   first profile in the workspace; otherwise just creates it.

When no projects exist, the sentinel is replaced with:
```
No projects yet. Add projects first.
```

### 1.6 Orphaned Items Section

Shows orphaned cached configurations and stray build directories. Visible
when either type exists (hidden otherwise — the common case).

**Title**: `Orphaned Items` with `Title` highlight.

**Orphaned configurations**: cached configs with build state not referenced
by any profile. Grouped by project key (sorted alphabetically). Each
project is a foldable node; each config within is a foldable node showing
the config key and its status.

**Stray build directories**: directories under `{root}/.nvim/build/` not
referenced by any cache entry. Detected via top-down pruning: the scan
reports the highest-level directory whose entire subtree contains no cache
entries. Directories that ARE cache entries (or parents of cache entries)
are skipped. Shown as flat items with `(stray)` suffix.

```
Orphaned Items  [D] delete

  ▶ App
    ▶ Debug:ninja-gcc-12 (built)
      Status: built
      Build dir: .nvim/build/App/Debug
  .nvim/build/OldProject (stray)
  ▸ Clean all
```

**Highlight**: Project nodes use `LoomworksUnconfigured`. Config nodes use
`resolve_config_status()` highlights. Stray dir items use
`LoomworksUnconfigured`.

**Actions**: `D` (delete) is mapped on config nodes and stray dir items.
All other action keys (`b`, `c`, `R`, `C`, `p`) are not bound — orphaned
items cannot be built or configured. Deletion shows the standard
confirmation dialog. `D` on a config node runs through `_run_deletion` like
Clean all: its build dir is kept (only the entry is dropped) when a live
configuration references it or it is, contains or lies inside a live build
dir under any spelling; otherwise the entry is `unknown` on disk before the
removal and dropped only after the removal succeeded (a failed removal keeps
it). The notification reports the outcome: removed, entry dropped with the
directory kept, entry dropped with no directory to remove, or not removed.

**Sentinel: Clean all**

After the last orphaned item:
```
▸ Clean all
```
Enter shows a confirmation dialog listing:
- All orphaned cached configurations (with state and build dirs)
- All stray build directories

On confirm: deletes orphaned cache entries + build dirs via `_run_deletion`,
then deletes stray build dirs. If nothing to clean, shows a notification.

### 1.7 Configuration Sets Section

Shows configuration sets from the merged config (loomworks.json + user.json).
Only appears when sets exist.

**Set node display**:
```
{fold_char} {modified_tag}{set_name}  {summary}
```

Where `{modified_tag}` = "+" if the set is modified (see [loomworks core §2.4](https://github.com/samienne/loomworks/blob/main/spec/core/three-file-model.md)),
empty otherwise, and `{summary}` is the set's description summary (§1.16). Shared-only sets (not in user.json) are dimmed (`Comment`).

Highlighted with `LoomworksActive` if the active profile belongs to this set,
otherwise `LoomworksActionable` (or `Comment` if shared-only).

**Set node actions**:

| Action | Behavior |
|--------|----------|
| `<CR>` | Action picker: Edit mappings, Edit description, Create profile from set, Delete |
| `e`    | Edit description (§1.16) |
| `D`    | Delete config set with confirmation dialog |

**Config set editing** (`<CR>` on a set node):

Opens a dedicated config set editor dialog. Shows each project in the
workspace with its current variant mapping and available configurations
(from module.info). The user can change each mapping via `vim.ui.select`
or set it to "None" to remove the mapping. Accept (`y`) applies changes
via `update_config_set_mapping()` for each changed mapping. Cancel (`q`)
discards changes.

Changed mappings may orphan existing cached configs (old variant no longer
referenced). This is intentional — orphans are cleaned explicitly via the
"Clean all orphaned items" action in the Orphaned Configurations section.

**Config set deletion** (`D` on a set node):

Shows a confirmation dialog listing:
- Profiles that reference this set (will become orphaned-set)
- Warning that cached configs will become orphaned

On confirm: `remove_configuration_set()`. Profiles that referenced the set
become orphaned_set. Cached configs for those profiles become orphaned. No
immediate deletion of cache entries — the user cleans via "Clean all orphaned
configs" in the Projects section.

**Set children** (when unfolded):
- Description (only when the set has one), rendered per §1.16
- Projects sub-group: `project_key → variant`
- Tools sub-group (if keyed tools detected): one item per detected tool

**Tool entry display**:
```
{marker} {tool_label} {suffix}
```

Where:
- `{marker}` = status marker for the corresponding profile (if materialized)
- `{suffix}` = status/progress info if materialized, empty if not
- Highlight follows same rules as full profiles

**Tool entry actions**:

| Action | Materialized profile exists | No materialized profile |
|--------|---------------------------|------------------------|
| `<CR>` | activate | activate (materializes first) |
| `b`    | build via profile | build via `run_profile_action` (materializes first) |
| `c`    | configure via profile | configure via `run_profile_action` (materializes first) |
| `R`    | rebuild via profile | nil (no-op) |
| `C`    | clean via profile | nil (no-op) |
| `D`    | delete profile with dialog | nil (no-op) |

**Sentinel: Create configuration set**

After the last config set, an interactive item:
```
▸ Create configuration set
```
Enter opens a picker with two kinds of options:

1. **Auto-detected templates** — generated by `generate_default_config_sets()`
   using `map_variant()` on all projects. Standard templates: "Debug" and
   "Release". Each template pre-fills project→configuration mappings by
   matching variant types across modules. Templates that match an existing
   config set name are excluded.
2. **Custom** — opens the config set editor dialog with empty mappings.
   User enters a name and manually selects variant per project.

Selecting a template creates the config set immediately with the
pre-computed mappings. No editor dialog — the mappings are deterministic.

This replaces the previous flow where all config sets started from the
editor dialog.

### 1.8 Projects Section

Shows all projects from the active set, including orphaned projects. Projects
are sorted alphabetically with orphaned projects at the end.

**Project node display**:
```
{fold_char} {modified_tag}{project_key} [{type}] {orphan_tag} {refresh_tag}  {summary}
```

Where:
- `{modified_tag}` = "+" if any child or the project declaration is modified
  (see [loomworks core §2.4](https://github.com/samienne/loomworks/blob/main/spec/core/three-file-model.md)), empty otherwise
- `{orphan_tag}` = "(orphaned)" if in cache but not in config
- `{refresh_tag}` = "!" if `needs_refresh` is true
- `{summary}` = the project's description summary (§1.16)
- Under a project's configuration/tool rows, a config unit whose built output
  was overwritten by a conflicting unit ([loomworks core §5.9](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)) carries an
  `[overwritten]` tag (highlight `LoomworksConflict`), matching the profile-side
  rendering (§1.5).

**Shared-only items** (exist only in loomworks.json, not in user.json) are
displayed with `Comment` highlight (dimmed). Module-generated default
configurations are also dimmed. Dimmed items become normal on first
interaction (auto-copied to user.json).

**Project children** (when unfolded):
- Description (only when the project has one), rendered per §1.16
- Path
- Refresh reasons (if any, with `!` prefix and `DiagnosticWarn` highlight)
- Configurations sub-group

**Configuration display** (keyed-tool modules):
Each configuration shows its available tools:
```
{fold_char} {config_name} {brief}  {summary}
  Description …                           ← only when it has one (§1.16)
  {fold_char} {tool_label} {progress}     ← one per detected/cached tool
    Status: {status}
    Build dir: ...
    Last configured: ...
    Generator: ...
    {fold_char} Targets ({total_count})       ← only when targets exist
      {fold_char} {type_group} ({group_count})
        {fold_char} {target_name}
          Links: dep1, dep2
```

**Configuration display** (non-keyed modules):
```
{fold_char} {config_name} {brief}  {summary}
  Description …
  {fold_char} Status: {status} {progress}
    Build dir: ...
    ...
```

**Saved test targets line** (read-only, modules with `parse_targets`):

A configuration's detail rows (after the description) and a project's
children (after the path) show its effective saved test-target list ([loomworks core §1.3.4](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) on one line when it has one:
```
  Tests: BaseTests, CoreTests, +7  (inherited from Tests)
```
- Names in list order, cut with `+N` to the window width; a name listed
  several times appears once per entry (args are not shown on this line).
  The source in parentheses — `own` is omitted, otherwise
  `inherited from <configuration>` or `project-wide`. An explicit empty list
  shows `Tests: none (explicit)`.
- When the unit is configured here, a missing entry ([loomworks core §1.3.4](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md), [loomworks core §8.9.3](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md))
  carries a ⚠ (`DiagnosticWarn`); unknown targets (unconfigured) are not
  flagged. An entry that resolves to a launch configuration is not marked
  differently on this line; `lw test --list` shows the kind.
- Entries whose args or `working_dir` come only from the shared layer and
  are stripped ([loomworks core §17.6](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)) show the trust diagnostic like other ignored
  fields. Neither args nor a `working_dir` is shown on this line.
- No editing on the status page in v1 and no new keys: the list is edited
  with `lw test-target` ([loomworks core §16.9](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)). An inline editor is a later addition.

**Targets sub-tree** (post-configure only, modules with `parse_targets`):

When a configuration has cached targets, a foldable "Targets (N)" node
appears in the unfolded tool entry detail view, where N is the total
target count. Targets are grouped by type under foldable sub-headers
showing the group name and count (e.g., "Executables (2)"). Within each
group, targets are sorted alphabetically by name. Targets with link
dependencies can be unfolded to show `Links: dep1, dep2, ...` on a
single line. Targets without dependencies are leaf nodes (no fold arrow).

Type group labels and display order:
1. `Executables`
2. `Static Libraries`
3. `Shared Libraries`
4. `Module Libraries`
5. `Object Libraries`
6. `Interface Libraries`

Only groups containing at least one target are shown.

**Configuration actions** (at the tool/status level):

| Action | Behavior |
|--------|----------|
| `D`    | Delete config with dialog |

**Tool entry highlight rules** (keyed-tool modules):

| Condition                       | Highlight              |
|---------------------------------|------------------------|
| Running                         | `LoomworksRunning`     |
| Deleting                        | `LoomworksDeleting`    |
| Active (matches active profile) | `LoomworksActive`      |
| Failed                          | `LoomworksFailed`      |
| Configured/Built (not active)   | `LoomworksConfigured`  |
| Unconfigured                    | `LoomworksUnconfigured`|

A tool entry is "active" when the active profile's tool_key matches the
entry's tool_key and the configuration variant matches the project's active
configuration.

**Non-keyed module highlight rules** follow the same pattern but without
tool_key matching — the entry is active when its variant matches the
project's active configuration.

**Launch configurations sub-group**

After the configurations group, each non-orphaned project shows a
"Launch:" group listing its launch configurations.

Each launch config item shows `{name}  {summary}  {runs}`:
- `{summary}` is the launch's description summary (§1.16). The launch items of
  a project form a summary column, at most 36 display columns and blank for
  launches without a description. This is the same layout rule as the CLI
  ([loomworks core §16.35](https://github.com/samienne/loomworks/blob/main/spec/core/headless.md)).
- `{runs}` is the open-ended tail: `target:<t>` or the command, then the args.
  It is dimmed and cut with `…` to the window width.

Actions:

| Action | Behavior |
|--------|----------|
| `<CR>` | Edit launch config (opens launch editor dialog) |
| `e`    | Edit description (§1.16) |
| `K`    | Full description, or the full command line when there is none |
| `D`    | Delete launch config with confirmation |

A "Add launch config" sentinel opens the launch editor for a new config.

The **launch editor dialog** edits: name, command, args (space-separated),
working directory, and environment variables (key=value pairs). Env vars
can be added (`▸ Add variable`) and removed (`D`). Inline name validation
prevents duplicates and invalid launch names ([loomworks core §8.7](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)). Accepts with `y`,
cancels with `q`.
- **Fields it does not show are kept.** Saving never drops `target`, `device`,
  `device_log`, `description` or any field it does not edit.
- **Description.** For an existing launch it shows a `Description ▸ <summary>`
  row that opens the description editor (§1.16). The description editor saves
  independently of the dialog's accept.
- **Rename.** Changing the name and accepting is a **rename** ([loomworks core §8.7](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md)): the
  same atomic operation as `lw launch rename`. Every field moves, and every
  profile's default target that named the launch follows. It is never a delete
  plus re-create.

**Sentinel: Add project**

After the last project (or as sole content when no projects exist), an
interactive item:
```
▸ Add project
```
Enter opens the project browser float (§1.14). Replaces the former `A`
keybinding.


### 1.9 Tasks Section

Diagnostic and recovery surface for active task lifecycle state.
Renders nothing when no tasks are running and no build-dir locks are
held — quiet during idle. Placed at the bottom of the status page
because it's only interesting when something is wrong; the day-to-day
reader sees workspace state first.

**Section content** (in render order):

1. Title line `Tasks  [N active]` where N is the active-task count.
2. Top action row `⟲ Reset all task & lock state` (warn highlight)
   — Enter opens a confirmation dialog; on confirm, cancels every
   active task and force-releases every held lock. Nuclear option for
   the case where bookkeeping has wedged.
3. One row per active task:
   ```
   ▸ {project_key} : {config_key} — {action}  [N/M]  {elapsed}
   ```
   - `{action}` is `configure` / `build` / `clean`.
   - `[N/M]` is the most recent progress update (omitted when none).
   - `{elapsed}` is the time since the task was registered (`30s`,
     `1m4s`). The spinner marker animates while the task is live.
   - **Enter** opens a `vim.ui.select` menu: `Cancel task` (calls
     `task:stop()` via `Workspace:cancel_task`) and `Open overseer`
     (opens the overseer task list for output inspection). Esc
     dismisses without action.
4. Sub-section `Build directory locks` (only when at least one lock
   is held or has a non-empty queue):
   ```
   ▸ {build_dir}  exclusive · shared(N) · queued(N)
   ```
   - Tokens appear only when their count is non-zero; entries with
     all zeros are elided by `get_build_dir_locks_info`.
   - A queue with no live holder (shared_count=0, exclusive=false,
     queue_depth>0) is highlighted with `DiagnosticWarn` — the
     visual cue for the "stuck PENDING" scenario.
   - **Enter** opens a `vim.ui.select` menu with one option
     `Force-release lock` (zero the counts, replay the FIFO queue).
     Idempotent with respect to the real holder's eventual release.
     Esc dismisses.

**Section invariants:**

- Renders nothing when `get_active_tasks()` and
  `get_build_dir_locks_info()` are both empty.
- Per-row Enter opens a menu rather than firing directly. Both
  actions are recoverable, but a misclicked cancel costs a full
  rebuild on a large project — the menu serves as a one-keystroke
  confirmation.
- Top-level reset uses the heavier confirmation dialog because it
  acts on multiple items at once.


### 1.10 Deletion Confirmation Dialog

Shown for all delete operations (`D` key). Floating window centered in editor.

**Content**:
1. Title (e.g., "Delete profile: Debug:ninja-gcc-12")
2. Running tasks that will be stopped (if any)
3. Items that will be removed (`disposition = clean`)
4. Items that will be reset (`disposition = reset`)
5. Items that will be kept (`disposition = keep`, referenced by another
   profile)
6. Confirmation prompt

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

### 1.11 Nuke Confirmation Dialog

Shown when `<C-n>` is pressed. Floating window centered in editor.

**Content**:
1. Title: "Reset workspace cache"
2. List of paths that will be deleted:
   - `<root>/.nvim/build/`
   - `<root>/.nvim/loomworks.cache.json`
   - each module's owned LSP database area,
     `<root>/.nvim/cache/<lsp_database_root>/` ([loomworks core §8.4](https://github.com/samienne/loomworks/blob/main/spec/core/module-interface.md), [loomworks core §4.6](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md) *Owned LSP
     database cleanup*) — listed only when present on disk
3. Confirmation prompt

**Root resolution**: Uses `ws.root` if a workspace is loaded, otherwise
resolves from cwd via `workspace.resolve_root()`.

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

**Safety checks** (in `nuke_cache(root)`):
1. Root must be an absolute path (rejects relative paths)
2. `loomworks.json` must exist at the root (confirms it is a real workspace)
3. Every path to delete is verified to be under `root/.nvim/` using
   normalized path prefix checking (prevents directory traversal)
4. An owned LSP database area is removed only when it is exactly the
   direct child `<root>/.nvim/cache/<lsp_database_root>` and neither it,
   `.nvim/cache` nor `.nvim` is a symbolic link or junction ([loomworks core §4.6](https://github.com/samienne/loomworks/blob/main/spec/core/state-lifecycle.md)
   *Owned LSP database cleanup*); nothing else under `.nvim/cache/` is
   touched

If any check fails, the operation aborts with an error notification and
no files are deleted. These checks are specific to the nuke operation —
the general io layer does not restrict deletion paths, because normal
config/profile deletion may delete build directories anywhere.

### 1.12 Help Dialog

Floating window showing all keybindings. Destructive keys (`R`, `C`, `D`,
`<C-n>`) have their key character highlighted with `DiagnosticWarn`.

### 1.13 Options Float

Triggered by `o` on a configuration or tool entry node in the Projects
or Profiles section. Opens a floating window showing the project's build
options for that configuration. Only available for configured projects
with a cached build directory.

**`Core:get_project_options(project_key, config_key) → (OptionGroup|Option)[]|nil`**

Resolves the build directory from cache and delegates to the module's
`get_options()`. Returns nil if the project is not configured or the
module does not support options.

The float uses a Tree widget with foldable groups. The module returns a
tree of `OptionGroup` and `Option` nodes. Each group shows its label and
child count. Each option shows `key = value`. BOOL values are highlighted
(ON = green, OFF = dimmed). Options with helpstrings show them as
children when unfolded. Options with choices show them in parentheses
after the value. Fold/unfold with `<Tab>`.

The float is read-only. Close with `q` or `<Esc>`.

### 1.14 Project Browser

The project browser is a float opened from the "Add project" sentinel line.
It scans workspace subdirectories asynchronously and shows detected project
types using each module's `detect()` method.

**Layout**: Tree widget in a `Snacks.win` float. Title: "Add Project".

**Entry display**: Each directory entry shows its name followed by detected
type tags (e.g., `MyProj  [<module>: <marker>]`). Directories matching
multiple modules show all tags. Already-added projects show `✓` with
`DiagnosticOk`. Directories with no detection show `Comment` highlight.

**Async scanning**: On open, `modules.scan_directory_async()` scans the
workspace root. On fold open, subdirectories are scanned lazily. Results
are cached in a browser-local dict. Pending scans show "scanning...".

**Filtered directories**: `.git`, `.nvim`, `.cache`, `.vs`, `.vscode`,
`node_modules`, `build`, `out`, `__pycache__`, and all hidden directories
(starting with `.`) are excluded from scanning.

**Keybindings**:

| Key     | Action  | Behavior |
|---------|---------|----------|
| `<CR>`  | enter   | Picker with Add/Remove by module type (see below) |
| `d`     | remove  | Remove project from workspace (with confirmation) |
| `r`     | refresh | Clear scan cache and re-scan |
| `q`     | close   | Close the browser |

**Project key derivation**:
- Root-level directories: basename as key, `path` field omitted
- Nested directories: relative path (with `/` → `_`) as key, explicit `path`
  field

**Enter picker**: Each browser entry has a context-dependent picker:
- Unadded types show `Add [type]`
- Already-added types show `Remove [type]`
- Single add action: always shows picker (user confirms)
- Mixed state: both add and remove options appear

**Configuration mapping dialog**: When adding a project to a workspace
that already has configuration sets, a mapping dialog opens instead of
adding immediately.

The dialog layout depends on the module type and workspace state:

**Keyed module, no tool selected** — tool row first, no mappings:

```
  Add "<project>" [<module>]

  Tool:  None ▸

  Project will be added without configuration mappings.

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool selected** — tool row first, then mappings:

```
  Add "<project>" [<module>]

  Tool:  <tool label> ▸

  Debug     Debug ▸
  Release   Release ▸

  Profiles to upgrade:
    Debug → Debug:<tool_key>

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool inherited** — when existing profiles already have
a tool, the tool is inherited automatically. No tool row; mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     Debug ▸
  Release   Release ▸

  [Enter] change  [y] accept  [q] cancel
```

**Non-keyed module** — mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     <variant> ▸
  Release   <variant> ▸

  [Enter] change  [y] accept  [q] cancel
```

The profile upgrade preview shows only profiles whose config set has
a non-None mapping for the new project.

- Enter on a mapping row opens `vim.ui.select` with configurations + "None"
- Enter on the tool row opens `vim.ui.select` with detected tools
- `y` accepts: chains decomposed operations (see below)
- `q`/Esc cancels: project is NOT added
- Skipped when no config sets exist or project has no detectable configs
- No success notifications — UI state changes are sufficient. Only
  errors are shown via `vim.notify`.

**Tool detection gating**: When the module has keyed tools, the project
browser ensures tool detection has completed before opening the mapping
dialog. If detection is still running, the dialog opens in the callback
after detection completes.

**Decomposed add-project operations**: On accept, the mapping dialog
chains three atomic operations. Each operation saves to disk and
remerges independently. Each intermediate state is valid — if the
process crashes between steps, no data is lost or corrupted.

1. `ws:add_project(key, type, path)` — adds the project entry to
   user.json. Project shows as unmapped.
2. For each config set with a non-nil mapping:
   `ws:update_config_set_mapping(set, key, variant)` — adds one
   mapping to one config set.
3. If a tool was selected or inherited:
   `ws:upgrade_profiles_for_tool(tool_entry)` — upgrades cached
   no-tool profiles to keyed profiles (renames, adds tool fields,
   creates skeleton cache entries). Extends existing keyed profiles
   with skeleton entries for the new project.

**Cache cleanup on removal**: The removal confirmation dialog shows all
cached configurations for the project that will be deleted. Entries with
build state (configured/built/failed) are listed with their build
directories. Skeleton entries (unconfigured) are silently included.

**Profile downgrade on removal**: When removing a project whose module
has keyed tools, the project browser checks whether it is the last
project of that module type. If so, the removal confirmation dialog also
shows a profile rename preview.

After confirmation:
1. `ws:remove_project(key)` removes the project from config and config sets.
2. Cached configurations for the project are deleted (entries removed from
   cache, build directories deleted asynchronously via safe deletion).
3. `ws:downgrade_profiles_from_tool(mod_type)` strips tool suffixes from
   affected profiles when the last keyed-module project is removed.

This is not "auto-clean" — it is an explicit user action with a
confirmation dialog showing exactly what will be deleted.

**File mutation**: All changes write to `loomworks.user.json` via Workspace
mutation methods. Each method saves and remerges independently. Published
items are written to `loomworks.json` only on explicit `:w` (see
[loomworks core §2.4](https://github.com/samienne/loomworks/blob/main/spec/core/three-file-model.md)).

Available Workspace mutation methods:
- `add_project(key, type, path?)` — add a project entry
- `remove_project(key)` — remove project + clean up config sets
- `update_config_set_mapping(set_name, project_key, variant)` — update
  one mapping in a config set
- `add_configuration_set(name, mappings)` — add a config set
- `remove_configuration_set(name)` — remove a config set
- `upgrade_profiles_for_tool(tool_entry)` — upgrade no-tool profiles
  to keyed profiles; extend keyed profiles with new project entries
- `downgrade_profiles_from_tool(mod_type)` — strip tool from profiles
  when last project of a keyed-module type is removed
- `compute_downgrade_preview(project_key)` — compute profile renames
  that would occur if a project were removed (pure query, no mutation)

### 1.15 Auto-refresh

The status page refreshes automatically on these events:
- `task_started`, `task_stopped`, `task_result`, `task_progress`
- `deletion_started`, `deletion_completed`, `deletion_failed`
- `active_set_changed`
- `operation_started`, `operation_finished`

Refreshes are coalesced via `vim.schedule` to avoid redundant redraws.

An animation timer (80ms) runs when any node has `spinning = true`, providing
smooth spinner animation for running/deleting states. The timer stops
automatically when no spinners are active.

---

### 1.16 Descriptions

Projects, user configurations, configuration sets and profiles may carry a
description ([loomworks core §1.10](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)). The first line is the **summary** and
the rest is the **body**. All description text is display-only and rendered
inert ([loomworks core §17.11](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md)). Control characters are shown visibly, a
buffer line never receives an embedded newline, and highlighting comes only
from `LoomworksDescription` ranges the renderer applies, never from the text.

**Summary on a node line.** The summary is appended after the node's existing
text, separated by two spaces and highlighted `LoomworksDescription`. It is
**fitted to the available width**:

- The width is the status window's text width, minus the node line's display
  width, minus the two-space gap and one column of margin, and **at most 60
  display columns**.
- The summary is cut in display columns (`strdisplaywidth`, never bytes) and ends
  in `…` when cut. When fewer than 12 columns remain, it is omitted from the node
  line; the expanded node and `K` still show it.
- The fit is recomputed on every render. The page re-renders on window resize.

Nodes that carry a summary: profile nodes (§1.5), configuration-set nodes
(§1.7), project nodes (§1.8), configuration rows (§1.8) and launch config
items (§1.8, as a column before the command line). Launch targets also show
their summary:
- on a profile's `Target:` row (§1.5);
- in the target picker and the launch picker (`name (launch)  summary`);
- in the launch editor's `Description ▸` row. A generated
configuration with a module-provided default description ([loomworks core §1.10](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) shows
it the same way.

**Expanded node.** The first child of an unfolded describable node is its
description:

- one `LoomworksDescription` leaf per description line, with the blank line
  between summary and body kept;
- each leaf cut to the window width with `…`;
- at most **8 lines**, followed by a `… N more lines — [K] full description` leaf
  when longer.

A module-provided default is labelled `(from project files)` on its first leaf.

**Hover (`K`).** On a describable node or any of its description leaves, `K`
opens the existing hover popup with the **full** description. The popup is
wrapped at its width, with no line or length cap. For a generated
configuration, the popup notes that the text comes from the project files and
cannot be edited here.

**Pickers and dialogs.** Wherever a picker or dialog lists describable items,
each entry shows `name  summary`, with the summary fitted to 40 display columns
and passed as a plain string with no highlight markup. This covers:

- the profile picker (`● key (status)  summary`);
- create-profile step 1, the configuration-set choice;
- the deletion confirmation dialog (§1.10), where the summary follows the
  title line so the user can confirm which item is going;
- the configuration-set editor and configuration editor dialogs. Each gains a
  `Description ▸ <summary>` row, and `<CR>` on that row opens the description
  editor. The editor saves the description itself, independently of
  the dialog's accept or cancel. The row is shown only for an existing set or
  user configuration.

Notifications name items by key only and never include description text.

The description editor's item kinds include **launch configuration**. Its title
is `Description — launch configuration <project>:<name>`.

**Description editor (`e`).** `e` on a describable node, or "Edit description"
from its `<CR>` picker or from an editor dialog's `Description ▸` row, opens a
floating scratch buffer in the style of a git commit message. The buffer
settings are `buftype=acwrite`, `bufhidden=wipe`, `filetype=loomworks_description`
and `textwidth=0`. The title is `Description — <kind> <name>`. Its content is:

```
<current description, or empty>

# Describe profile 'Debug:ninja-clang-18.1.0'.
# The first line is the summary shown in lists; add a blank line, then details.
# Lines starting with '#' are ignored. Save an empty description to remove it.
# :w saves · :q! discards
```

- `:w` (BufWriteCmd) removes the `#` lines, normalises the text ([loomworks core §1.10](https://github.com/samienne/loomworks/blob/main/spec/core/data-model.md)) and
  applies it:
  - an empty result **removes** the description;
  - an unchanged result writes nothing.

  After a save the buffer is marked unmodified and `:q` closes it; `ZZ` / `:wq`
  save and close.
- A refused description (a control character, or more than 4096 bytes) is
  reported inline as an error and the buffer stays modified.
- Closing without saving (`:q!`) discards the edit.
- The syntax highlights the summary line, marks the summary past 72 columns
  (`WarningMsg`, advisory only), and dims `#` lines. It does not use the
  `gitcommit` filetype, so commit-message plugins and ftplugins do not attach.
- Saving an edit to a `shared` item materialises it ([loomworks core §2.4](https://github.com/samienne/loomworks/blob/main/spec/core/three-file-model.md)). A published
  item then shows `+`.
- On a generated configuration, `e` does not open the editor. It notifies that
  generated configurations take their description from the project files, and
  that a user configuration inheriting it can carry its own.

## 2. Highlight Groups

| Group                    | Default link      | Usage |
|--------------------------|-------------------|-------|
| `LoomworksActive`        | `DiagnosticOk`    | Active profile, active set |
| `LoomworksBuilt`         | `DiagnosticOk`    | Built configurations |
| `LoomworksConfigured`    | `DiagnosticInfo`  | Configured (not yet built) |
| `LoomworksUnconfigured`  | `Comment`         | Never configured |
| `LoomworksFailed`        | `DiagnosticError` | Failed configure or build |
| `LoomworksRunning`       | `DiagnosticWarn`  | Running tasks (non-active) |
| `LoomworksDeleting`      | `DiagnosticError` | Deletion in progress |
| `LoomworksUnknown`       | `DiagnosticWarn`  | Unknown state (partial deletion) |
| `LoomworksActionable`    | `Normal`          | Actionable items (sets, configs) |
| `LoomworksConflict`      | `DiagnosticWarn`  | Output-artifact conflict / overwritten unit (§1.5, §1.8) |
| `LoomworksDescription`   | `Comment`         | Description summaries and description lines (§1.16) |
| `LoomworksStale`         | `DiagnosticHint`  | `[stale — reconfigure]` hints, incl. the compiler-cache mismatch (§1.5); the `N suggestions` line (§1.1) |

Users can override these by defining the highlight groups before plugin load.

---

## 3. Winbar / Statusline Component

`lualine/components/loomworks.lua` provides a lualine component for
winbar display.

**Default display**: `{set_name} {join} {project}/{configuration}`

Where `{join}` defaults to `\u{e0b1}` (powerline thin right arrow) with
spaces.

**Configurable via `show` option**: array of parts to display:
- `"set_name"` — configuration set name
- `"project"` — project key for current buffer
- `"configuration"` — active configuration
- `"tool_key"` — tool key (e.g., the active profile's `tool_key`)

Every piece of workspace data the component inserts (set names, project keys,
configuration names, tool and profile keys, status) is made inert before it
reaches the statusline: control characters are removed and `%` is doubled to
`%%`, so a name from a cloned `loomworks.json` cannot inject statusline items,
highlight groups or expressions. The component's own highlight escapes, icons
and join string are not affected. This is the display-text rule of [loomworks core §17.11](https://github.com/samienne/loomworks/blob/main/spec/core/trust.md). The
component never shows descriptions.

**Returns empty** when:
- No workspace loaded
- No active profile
- Current buffer is not in any project

**Status markers.** With status icons enabled (the default; `status_icons =
false` disables them), the set name is prefixed with a marker for the active
profile's aggregate state (`buf_status().profile_state`) and the
project/configuration with one for the buffer's unit (`buf_status().status`).
Running states animate the spinner. The glyphs are short single characters
shared with the status page's meaning; each marker is coloured with the
**foreground** of its highlight group so it reads independently of the
surrounding text colour. The colour is applied through lualine's own
component highlights (`create_hl` / `format_hl`), so the marker keeps the
section's background, and the text after it returns to the section highlight
(`get_default_hl`) — never raw `%#Group#…%*` escapes, which would reset to
`StatusLine`/`WinBar` and carry the group's own background. This holds in
statusline and winbar sections alike, and the group's colour is re-read on
every redraw, so a colourscheme change is picked up. The diagnostics
indicator (`⚠` / `✗`) is coloured the same way.

| State | Glyph | Highlight |
|-------|-------|-----------|
| `built` | ✓ | `DiagnosticOk` |
| `configured` | ◐ | `Comment` |
| `unconfigured` | ○ | `DiagnosticError` |
| `mixed` (aggregate: units disagree, none failed or running) | ○ | `DiagnosticWarn` |
| `configure_failed` / `build_failed` / `failed_configure` / `failed_build` | ✗ | `DiagnosticError` |
| `unknown` | ? | `Comment` |
| `configuring` / `building` | spinner | `DiagnosticWarn` |
| `deleting` / `cleaning` | spinner | `DiagnosticError` |

`unconfigured` is red because an unconfigured active unit is not a neutral
resting state any more: it means the language server for that project is
withheld (core §9.8, §4 below). `mixed` is amber — part of the profile is
usable, part is not.

**`buf_status(bufnr)`** (public API, `loomworks.buf_status`) returns the table
this component renders, or `nil` when there is no active configuration set or
the buffer is in no project. Fields: `profile_key`, `set_name`, `tool_key`,
`project`, `configuration`, `status`, `profile_state`, `diagnostic_severity`,
and **`lsp`** — the buffer's per-buffer LSP status from core §9.8 (`none`,
`held`, `ok`, `withheld_unconfigured`, `withheld_no_db`, `withheld_error`).
Because `buf_status` is `nil` without an active profile, the same value is also
available unconditionally from **`loomworks.lsp_buf_state(bufnr)`**, which
returns `none` for buffers loomworks has no LSP opinion about. The status page
LSP section may reuse it to explain a missing client (e.g. "clangd withheld —
active configuration not configured on this machine").

## 4. LSP Status Component

`lualine/components/loomworks_lsp.lua` provides a small lualine component
meant to sit **next to lualine's built-in `lsp_status`** component. `lsp_status`
shows the clients that are attached; a withheld server (core §9.8) has no
client, so `lsp_status` alone shows nothing and the absence is
indistinguishable from "no server for this filetype". This component fills
that gap:

| `lsp_buf_state(bufnr)` | Renders |
|------------------------|---------|
| `withheld_unconfigured` | `(unconfigured)` in `DiagnosticError` |
| `withheld_no_db` | `(no db)` in `DiagnosticError` |
| `withheld_error` | `(ws error)` in `DiagnosticError` |
| anything else (`none`, `held`, `ok`) | empty string |

"In `DiagnosticError`" means that group's foreground on the section's own
background, applied through lualine's component `color` option (so lualine
restores the section highlight after the component — no raw `%#…#`/`%*`
escapes); a user-supplied `color` option overrides it.

It reads `loomworks.lsp_buf_state` (not `buf_status`) so it also renders when no
profile is active — the no-active-profile case is `withheld_unconfigured`
(core §9.1, §9.8). It renders empty for buffers outside any workspace and when
loomworks is not loaded. The text is a fixed string (no workspace data), so the
display-text rule of §3 does not come into play. It refreshes on the same events
as §3 (active-set change, task completion, workspace change) plus a change of
the buffer's LSP status, and costs nothing while idle.

Example:

```lua
lualine_x = { "lsp_status", "loomworks_lsp" }
```
