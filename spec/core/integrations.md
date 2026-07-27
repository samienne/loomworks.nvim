> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 9. LSP Integration

LSP integration is split between a thin core dispatch layer
(`lua/loomworks/lsp.lua`) and per-server integration files
(`lua/loomworks/integrations/lsp/<server>.lua`). Core is module-agnostic:
modules emit opaque `lsp_configs()` entries keyed by `server` name, and
core routes them to the matching integration. Integrations are discovered
from every runtime path, so drop-in integrations (either in the user's
own config or in a sibling plugin) register automatically alongside the
built-in ones.

### 9.1 Module interface (§8.4 `lsp_configs`)

Modules produce entries shaped as `{ server = "...", root_dir = ...,
<per-server fields>... }`. Core only inspects `server` to dispatch;
integrations parse the remaining fields. Modules may traverse core
domain objects (Project, ConfigUnit) to resolve cross-configuration
references inside themselves, so paths emitted in the entry are
fully resolved.

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
  to `active_set_changed` and `workspace_changed` and fans out to every
  integration's `on_active_set_changed` / `on_workspace_changed` hook.
  Integrations don't register listeners themselves.
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
| `on_active_set_changed()` | Called on profile/active-set change |
| `on_workspace_changed()` | Called on workspace swap / first load |
| `on_unexpected_exit(info) → decision` | Restart policy for an unexpected client death (see §9.6). `info` carries `{ server, root_dir, exit_code, signal, attempt, args }`. `decision` is `{ restart: boolean, args?: string[], reason?: string }` |
| `reset(root_dir)` | Clear any adaptive state for a root (UI Reset action) |
| `reset_label` | Display label for the UI Reset row |

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

- [`spec/integrations/lsp/clangd.md`](spec/integrations/lsp/clangd.md)
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

---

## 10. SDK Provider Contract

An SDK is a resolved platform installation (e.g., an Android NDK, an
embedded vendor toolchain, a cross-compiler distribution) that supplies
tools to one or more modules. SDK providers
are pluggable: each provider lives at `lua/loomworks/sdks/<id>.lua`
and registers itself by being required from `lua/loomworks/sdks/init.lua`
or another runtime path file.

### 10.1 Provider interface

Each provider table exposes:

| Field | Purpose |
|-------|---------|
| `id` | Provider identity (e.g., `"android-ndk"`) — stable across versions |
| `display_name` | Human-readable name shown in pickers and status |
| `detect_all() → { path, version }[]` | Enumerate installations on the host. Pure detection — no validation, no domain object creation |
| `validate(path) → boolean` | Return whether a given path looks like a valid installation of this SDK type |
| `create_sdk(key, path, version) → SDK` | Construct a `loomworks.SDK` domain object from a validated installation |
| `query_capabilities(sdk, module_id) → table\|nil` | Return opaque capability data this SDK can offer to a given module, or `nil` if it has nothing for that module. `module_id == nil` returns the supported module ids array |

**Declaring an installation.** An SDK is normally declared by supplying a path,
which the provider validates — identifying the installation and deriving the
facts (such as version) that the key is built from. A provider MAY derive a key
that encodes more than the version (for instance a path-derived token, so two
installations of the same version at different paths stay distinct); a
provider-derived key is the installation's identity and MUST be preserved
verbatim across save/load.

A user MAY **force** a declaration whose path fails identification — an
installation that cannot report on itself — by supplying the identifying facts
explicitly. The path MUST still exist, so a mistyped path is still refused. A
forced declaration carries only the facts the user gave: where a version was not
supplied it is unknown, and the installation therefore forfeits version-based
selection (§16.3) and is referenced by its full key.

### 10.2 SDK domain object

`loomworks.SDK` (`lua/loomworks/sdk.lua`) wraps a resolved
installation. Fields:

| Field | Purpose |
|-------|---------|
| `key` | Identity key, persisted in user.json |
| `_type` | Provider id |
| `_version` | Detected version (or nil) |
| `_path` | Resolved installation path |
| `_resolved` | Whether the path is currently valid |
| `_intent` | `"shared"` / `"local"` for the publish/working-copy model |
| `_provider` | Back-reference to the provider table |

`SDK:query(module_id)` delegates to the provider's
`query_capabilities`. Returns `nil` when the SDK is unresolved or has
nothing for that module.

### 10.3 Capability shape

Capability data is **opaque to core** — only the requesting module
interprets it. A typical shape includes paths to platform tools
(compilers, packagers, simulator binaries), toolchain files,
architecture lists, and any flags that must be threaded into the
module's task generation. Each provider documents its shape per
module in its own spec file.

### 10.4 Profile-level pinning

A profile may pin an SDK by `key` in user.json. On reload, the SDK
is resolved by `key` against the workspace's known providers. If the
provider can no longer find the installation (e.g., the SDK was moved
or uninstalled), the profile renders as incomplete with a rebase
action. No fallback guessing — incomplete profiles surface
explicitly.

When a profile has an SDK and a module asks for a tool, the resolver
consults the SDK first via `SDK:query(module_id)`. If the SDK
returns nil, the module falls through to host-tool detection. If
neither yields a tool and the profile has no explicit override, the
profile is incomplete.

**Incomplete profiles refuse build operations.** Configure, build,
launch, and debug all gate on a buildability check at every entry
point: an incomplete profile can be created, edited, persisted to
loomworks.json, and shared with collaborators, but cannot be
executed against. The error is module-agnostic and points the user
at the status page to assign a tool/SDK. Without this gate the
build chain runs with nil tool data, the build directory resolves
from a config name that may have fallen back to a phantom
Configuration, and on-disk artefacts come out malformed.

### 10.5 SDK provider implementations

Each SDK provider documents its detection logic, validation rules,
and per-module capability shape in its own spec file:

- [`spec/sdks/cpp_compiler.md`](spec/sdks/cpp_compiler.md) —
  User-declared C/C++ compiler (cross-compiler / custom build).

Third-party providers follow the same shape: implement the contract
above and document the per-module capability shape alongside.

Optional provider hooks beyond the base contract:

- `path_prompt: string` — overrides the generic `<display_name>
  SDK path` text in the Add-SDK dialog. Useful when the
  installation is not a directory (e.g. a compiler binary).
- `derive_key(info, path) → string` — overrides the default
  `<type>-<version>` key shape. Useful when one user can have
  multiple distinct installations of the same type and version
  (e.g. two custom compiler builds at different paths).
- `display_name_for(sdk) → string` — overrides
  `SDK:display_name()` per instance so labels can depend on
  query-time information (e.g. detected compiler family).

### 10.6 Future direction

Profile-level toolchain selection is now language-keyed: profiles
carry a flat array of tool keys (`profile.tools`), each tool declares
its language coverage (`Tool.languages`), and each Configuration
declares the languages it needs (`Configuration.languages`, defaulting
to `module.languages`). SDK-supplied tools land in their module's
`_tools` registry via `Workspace:_enrich_tools_from_sdks` on every
remerge, identified by the same key shape host tools use so
cross-module identity is preserved. SDK refresh remains cheap because
the registry is rebuilt from cache + detection on each load —
profiles store only keys, not tool_data, except in the legacy
shape which migrates transparently on first save.

Post-configure language detection (cmake file-api, meson introspect)
is a future refinement — a soft diagnostic that suggests adding a
language to a configuration when the actual configure enabled more
than was declared. Not authoritative; user remains the source of
truth for `Configuration.languages`.

---

## 11. Device Interface Contract

Devices are physical or emulated deployment targets (phones,
simulators, embedded boards). Any module may opt in to device
support; SDK providers may also expose devices in the future. Core
discovers device-capable modules and routes all device operations
through them — no per-module knowledge in core.

### 11.1 Device domain object

`loomworks.Device` (`lua/loomworks/device.lua`) is identified by
its `serial` string. Runtime-only — not persisted in cache or
user.json. Workspace owns `_devices` (serial → Device), populated on
demand via `Workspace:scan_devices()`.

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `serial` | string | Stable device identifier |
| `display_name` | string | Human-readable label |
| `state` | string | `"online"` / `"offline"` |
| `provider` | string | Module id that owns this device type |
| `properties` | table | Provider-specific extras |

### 11.2 Module opt-in

**Static property:**

| Property | Type | Description |
|----------|------|-------------|
| `has_devices` | `boolean` | `true` if this module's launch targets may require device deployment. Default `false`. |

**Methods** (all optional, only meaningful when `has_devices = true`):

**`list_devices(tool_data, callback)`** *(async)*

Enumerate connected devices. Calls `callback(devices)` where each
device is `{ serial, display_name, state, properties }`. The module
runs the device connector tool and parses its output.

**`device_targets(project_ctx, active_config) → table[]`**

Return device launch target descriptors for the active configuration.
Each descriptor has `{ id, label, requires_device }`. These appear in
the launch target picker alongside module targets and command-type
launches.

**`device_install(tool_data, device_serial, artifact_path) → { cmd, args, env?, check_output? }`**

Return an overseer-compatible command spec for installing an
artifact onto a device. Does NOT execute the command — core runs it
via overseer. Always reinstalls (no freshness tracking).

`check_output(lines: string[]) → string|nil` is an optional failure
detector. Some device connectors exit with status 0 even when an
install is rejected by the device-side package manager; without
parsing the output, the build → deploy → install → launch chain
falls through silently and the device launches the previously
installed version of the app. Returning a non-nil string fails the
install task and breaks the chain. Modules that wrap exit-code-honest
connectors may omit this field.

**`device_launch(tool_data, device_serial, launch_info) → { cmd, args, env?, check_output? }`**

Return a command spec to launch the installed app on a device.
`launch_info` is module-specific metadata produced by
`resolve_launch_info()`. `check_output` follows the same contract
as `device_install` — used to surface launch failures that the
connector reports in stdout while exiting 0.

**`device_stop(tool_data, device_serial, bundle_name) → { cmd, args, env?, check_output? }`**

Return a command spec that force-stops the app on the device.
Session tracker calls this from `stop()` when the active run is a
device launch so stop paths actually terminate the on-device process
rather than merely closing the local log stream. `check_output`
follows the same contract as `device_install`.

**`device_pid(tool_data, device_serial, bundle_name) → { cmd, args, env? }`**

Return a command spec that, when run, prints the PID of a running
app on the device. Used by the session tracker for two purposes:
(1) initial PID discovery right after launch, and (2) periodic
polling to detect when the app has exited so the log stream can be
torn down automatically.

**`device_log(tool_data, device_serial, opts?) → { cmd, args, env? }`**

Return a command spec that streams device logs on stdout. `opts` is
an optional hint table (e.g., `opts.pid` for device-side filtering),
but the core `device_log` view does not rely on device-side filters
— it parses and filters the stream client-side. Modules may expose
whichever opts make sense.

**`device_log_clear(tool_data, device_serial) → { cmd, args, env? }`**

Optional. Return a command spec that flushes the device's log buffer.
Called by the session tracker right before starting a fresh stream so
the view doesn't mix in stale entries. Best-effort — errors here are
non-fatal.

**`resolve_artifact(project_ctx, active_config) → string|nil`**

Return the absolute path to the built artifact for device deployment.
Module-specific knowledge of where the build system places output.

**`resolve_launch_info(project_path, config_info, tool_data) → table|nil`**

Extract launch metadata from project files. Returns a table that is
passed to `device_launch()` as `launch_info`. Shape is
module-specific.

### 11.3 Launch flow with devices

The launch flow (§8.7) is extended when the target requires a device:

```
build → file-deploy → device-install → device-launch
```

1. **Build**: same as §8.7 — build dependencies, then build self.
2. **File-deploy**: same as §8.8 — copy artifacts between projects.
3. **Device check**: if `target:requires_device()` is false, proceed
   to normal launch/debug (existing path, unchanged). Otherwise:
4. **Device selection**: if the profile has no device serial, prompt
   with `vim.ui.select` populated from `list_devices()`. On
   selection, persist to profile.
5. **Device install**: call `resolve_artifact()` to find the artifact
   path, then `device_install()` to get the command spec. Execute via
   overseer as a tracked task. On failure, stop the chain with error.
6. **Device launch**: call `resolve_launch_info()` then
   `device_launch()`. Execute via overseer.
7. **Log stream** (best-effort):
   a. Resolve the launched app's PID via `device_pid()` (polled
      briefly — launch returns before the process is up).
   b. Clear the device log buffer via `device_log_clear()` (when the
      module provides it) so stale entries don't show up in the
      view.
   c. Start `device_log()` as a streaming task and hand its lines to
      the `loomworks.device_log` module, which parses each line,
      applies a session prefilter (PID OR proc-contains-bundle,
      union semantics), writes matches to a ring buffer, and renders
      filtered entries into a bottom-split scratch buffer.
   d. Start a periodic pidof poll (~3 s) on the session tracker.
      When the PID is gone for two consecutive polls the session
      tracker treats the app as exited, stops the log stream, and
      clears the active run.

   Failure at any step surfaces as a warning and does not fail the
   launch chain — the app is already running, we just can't follow
   its output this time.

Device targets always use launch mode in v1 (no device debug — see
BACKLOG.md "Native device debug").

### 11.4 LaunchTarget device support

LaunchTarget supports three target types:

| Descriptor field | Target type | Source |
|-----------------|-------------|--------|
| `target` | Module target (executable) | Module's `parse_targets` discovery |
| `launch` | Command launch | loomworks.json launch section |
| `device_target` | Device target | Module's `device_targets()` |

The `device_target` field stores the target ID.
`LaunchTarget:requires_device()` returns `true` when `_device_target`
is set.

The target picker collects from all three sources:
1. Launch configs from projects (`project.launch` dict)
2. Executable targets from `ConfigUnit.targets`
3. Device targets from modules (`module.device_targets()`)

### 11.5 Device interface implementations

Devices are typically implemented inside the module that knows the
relevant connector tool. No v1 core module ships a device interface;
device-capable modules (e.g. mobile/embedded targets) live in
separate plugins and document their connector usage in their own
specs.

---

## 12. Overseer Integration

### 12.1 Task generation

Modules provide task definitions via their `tasks()` function. Each task
definition includes:
- `builder()` — returns an overseer task specification
- `name` — display name
- `loomworks` — metadata: project_key, action, configuration_key, build_dir,
  tool_data, cmake info

### 12.2 Task tracking component

`loomworks.task_tracker` is an overseer component injected into every
loomworks-spawned task. It:

1. Registers the task on the appropriate ConfigUnit
2. Parses output for progress (module-specific parser)
3. On completion: records the task result to cache, unregisters from
   ConfigUnit

### 12.3 Task lifecycle

```
collect tasks → check readiness → launch/skip/defer → track → complete → record result
```

All tasks wait for pending deletions before starting.

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
| `"auto"` | Always load silently when a workspace file is found in cwd. Notify via `vim.notify`. |
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

All checks use **cwd only** — no parent directory walking. Use
`:LoomworksInit` for workspaces in parent or non-cwd directories.

**Detection order**: `loomworks.json` is checked first, then
`.nvim/loomworks.user.json`. Either file is sufficient to identify a
workspace root.

### 13.3 Behavior

When a trigger fires:
1. Check if `loomworks.json` or `.nvim/loomworks.user.json` exists in
   cwd (two `stat` calls).
2. If neither found → no-op.
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

Loading a workspace (whether via auto-load or `:LoomworksInit`) always:
- Reads `loomworks.json` (if it exists), `loomworks.cache.json`,
  `loomworks.user.json` asynchronously (non-blocking)
- When loomworks.json does not exist, the shared baseline is empty
  (no shared projects, config sets, or profiles)
- Creates `.nvim/loomworks.cache.json` if it does not exist
- Emits `workspace_changed` and `active_set_changed` events once
  initialized
- Starts asynchronous tool detection in the background
- Reports initialization and detection progress via fidget.nvim
  (if available)

### 13.5 Workspace initialization (`N`)

When no workspace exists (no loomworks.json, no user.json), the user
presses `N` on the status page to initialize:

1. Creates `.nvim/loomworks.user.json` with minimal content
   (`{ "_meta": { "version": 2 } }`)
2. Loads the workspace from user.json (empty shared baseline)
3. The status page shows an empty workspace with "Add project" sentinel

The user then follows the normal workflow: add projects via the project
browser, create configuration sets, create profiles.

No loomworks.json is created during initialization. It is created only
when the user explicitly publishes (`:w`).

### 13.6 Limitations

- **No file watching for workspace file creation**: If loomworks.json or
  user.json is created after Neovim starts and no `:cd` occurs, use
  `:LoomworksInit` manually.
- **No parent directory walking**: Auto-load only checks cwd, not parent
  directories. Opening Neovim in `workspace/src/` will not find
  `workspace/loomworks.json`. Use `:LoomworksInit` or `:cd` to the root.

## 14. Neovim Commands

| Command | Args | Description |
|---------|------|-------------|
| `:LoomworksInit [path]` | Optional directory | Initialize workspace (default: cwd) |
| `:LoomworksInfo` | None | Open/focus status page |

---

