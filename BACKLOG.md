# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Device log streaming: sluggishness persists after stream ends

After a harmony device session ends, editor responsiveness stays
degraded until the user manually disposes the hilog task via
`:OverseerOpen`. Closing our device_log bottom-split doesn't fix
it; `session_tracker.stop_run` already calls `task:stop()` +
`task:dispose()` on tear-down, so either that path isn't firing
or the dispose doesn't fully clean up.

Candidate causes to investigate:

- Overseer's JobstartStrategy still creates a hidden output buffer
  even with `use_terminal = false`, and appends every stdout chunk
  via `nvim_buf_set_lines`. Long sessions can produce
  hundreds-of-thousands-of-line buffers. If any statusline /
  winbar / autocmd pattern iterates listed buffers (or walks lines
  in them), that buffer becomes a global toll until disposed.
- Subscriptions registered via `task:subscribe("on_output_lines", ...)`
  capture the device_log view closure. If overseer's bookkeeping
  keeps the handler after complete, the closure stays pinned.
- An event / autocmd on the task buffer might still fire after
  process exit.

Options if it comes up again:

- **Auto-dispose on stream end.** When `on_complete` fires (or
  when `device_log.stop` is called) schedule the task for
  disposal. Users lose post-mortem raw-stream access but gain a
  clean editor; our ring-buffered view already keeps the last
  5000 parsed records for inspection.
- **Truncate the overseer buffer periodically** to a rolling
  window (keep memory bounded without disposing the task).
- **Bypass overseer entirely** for the hilog invocation — spawn
  via `vim.uv.spawn` with a pipe, read lines directly, expose
  stop via `device_log.stop_session`. Loses the "one task list"
  story for this task type but eliminates the buffer-growth
  problem.

Diagnostic first step when someone hits this: check the task's
buffer line count during a sluggish session (`:OverseerOpen` →
inspect the task's output buffer) to confirm the buffer-size
hypothesis before changing anything.

---

## MSVC toolchain support for the meson module

Meson builds fine with MSVC (`cl.exe`) on the ninja backend, but only
when invoked under an environment where `vcvarsall.bat` has run — that
sets `INCLUDE`, `LIB`, `PATH`, etc. for the target architecture. The
meson module's compiler detector (`lua/loomworks/compilers.lua`)
currently only finds gcc/clang on PATH; `cmake_kits.lua` already has
the MSVC + vcvarsall plumbing for cmake.

To add MSVC-meson kits:

- Extend `compilers.detect` (or a sibling `msvc_kits`-style helper) to
  enumerate VS installations via `vswhere.exe`, the same way
  `detect_msvc_kits` in `cmake_kits.lua` does.
- When the picked tool carries a `vcvarsall` field, the meson module's
  `tasks()` needs to wrap the configure / compile commands so they
  run under the vcvarsall env. Easiest shape: generate a `cmd.exe /c
  "call vcvarsall.bat arch && meson setup ..."` wrapper, the way
  cmake currently does. The wrapper shape should live next to the
  meson task builders, not inside `compose_task_env`, because it
  changes the *command* shape, not just the environment.
- `MesonTestUnit` should prepend MSVC redist DLL locations (the
  per-arch directories under the installation's `VC/Redist/...`)
  rather than a plain `compiler_bin_dir` — MSVC compilers don't ship
  runtime DLLs next to `cl.exe`.

Scope note: this is the reason `cmake` can pick "Ninja + MSVC" today
but `meson` can't. Tracked separately from the gcc/clang support that
already landed.

---

## Strict separation of auto-generated vs user configurations

Larger architectural rework of the configuration model. Replaces the
current "user edits merged on top of the same-named default in place"
approach with a clear two-tier model:

- **Auto-gen configs** are read-only, regenerated every load from the
  module (harmony: build-profile.json5, cmake: CMakePresets.json +
  defaults). Never persisted. UI shows them with edit actions disabled.
- **User configs** are explicit, named entries in loomworks.json /
  user.json with distinct names. Typically set `inherits:` to reference
  an auto-gen or another user config as base. Always persisted as the
  user wrote them (no diff-vs-default magic).
- **No name collisions** between auto-gen and user namespaces.
- **`configuration_set` mappings** point to either — both are valid targets.
- **Rebase on orphan** = change the `inherits:` value. When a user
  config's base is missing, UI shows `[orphan base]` + rename/rebase
  action.

UX concession for the "quick edit" ergonomic: on auto-gen entries, add
a single-click `Override this config…` action. Prompts for a name
(suggested default like "Debug-custom"), creates a user config with
`inherits:` set, and optionally rewrites the current set mapping to
point at the new user config.

Wins:
- No more bloated user.json with duplicated full configs
- Silent-rename data-loss becomes visible (orphan badge + rebase)
- Clean mental model for users: "mine vs the module's"
- Compatible with the existing `inherits` machinery

Supersedes the narrower "[stale] badge for source-missing configurations"
idea below. Requires: Configuration class split (auto-gen vs user source),
UI edit-action gating, a migration path that drops user.json entries
whose content exactly matches the auto-gen (self-heals existing bloat).

Scope: moderate — affects Configuration serialization, merge, UI edit
paths, and configuration_set resolution. Defer until core-cleanup
aftermath is verified stable.

## Visually distinguish stale / source-missing configurations

Configurations in user.json that no longer match any auto-generated
configuration (e.g. harmony `ohos`/`default` entries that predate the
ABI-in-identity rework, or a preset that a cmake project removed) are
still rendered as first-class options. The domain already tags them
`_source_missing = true`; surface that in the status page with a
`[stale]` badge beside the name so users can tell them apart from
intentionally user-declared configurations. Delete action is already
available (requires `is_user`). Do NOT auto-delete — user may have
tuned values on those entries.

## Plugin-based loomtest adapter discovery

Mirror the existing plugin-based module registry idea: loomtest should
auto-discover test adapters by scanning a conventional directory
(`lua/loomtest/adapters/<name>.lua` on the Neovim runtimepath). Each
file self-registers with `loomtest.register_adapter(...)`. Third-party
plugins can ship new adapters without editing loomtest itself.

Under this pattern, `lua/loomworks/loomtest_adapter.lua` would move to
something like `lua/loomtest/adapters/loomworks.lua` or stay in the
loomworks tree and just follow the same self-registration contract.
Keymaps for `<leader>t*` move out of loomworks entirely — loomtest
ships its own default keymaps.

Prerequisite for eventually splitting loomtest into its own repo
cleanly.

## Pluggable debug adapter architecture

`lua/loomworks/debug.lua` currently hardcodes behavior for nvim-dap and
has static tables of known adapters per language (`codelldb`, `cppdbg`,
`pwa-node`, etc.). To let third-party plugins add new debuggers
(gdb-mi, rust-analyzer DAP, custom remote debuggers) without editing
core, the debug layer should follow the same pattern as LSP integrations:

- Core `debug.lua` keeps a thin dispatcher and a registry of backends.
- Each backend implementation lives in
  `lua/loomworks/integrations/debug/<backend>.lua` (or an external
  plugin path). Backends self-register for specific adapter/language
  combinations.
- Modules declare opaque `debug_configs(...)` entries the way they
  already emit `lsp_configs` — core routes entries to the registered
  backend by name.

Retrofit would mirror the LSP refactor: define the entry shape, move
nvim-dap wiring out of `debug.lua` into an integration file, and have
`resolve_adapter` / `run` read from the registry rather than hardcoded
tables. Deferred until we have a concrete second adapter to validate
the design against.

## Streaming device scan into picker

Currently `Workspace:scan_devices()` waits for all modules' `list_devices`
callbacks to complete before opening the picker. On slow systems, `hdc
list targets` can take a couple of seconds, leaving the user staring at
"scanning for devices..." before the picker appears.

Ideally the picker would open immediately with results streaming in. This
requires a dynamic-source picker — not supported by `vim.ui.select`.
Options to investigate:
- Use Snacks.picker directly with `source = fun(cb)` or a dynamic items
  mechanism (Snacks is already a hard dependency)
- Cache previous scan results and show them immediately while re-scanning
  in the background, updating the visible list when new results arrive
- Start scans on workspace load so results are cached before the user
  opens the picker

Same treatment would benefit kit/SDK pickers and any other async source.

---

## Device debug (attach to app on device)

Not in v1. HarmonyOS hdc supports remote debugging via `hdc jpid` +
JDWP/LLDB forwarding. Would extend session_tracker's device path to
support `mode = "debug"` for device targets. Currently device targets
always use launch mode regardless of user input.

---

## Device log view — follow-ups

The device-log view (bottom-split, parsed + filtered client-side)
lands with enough to be useful: session prefilter (pid OR
proc-contains-bundle), soft filter (level / regex / tag / pid),
ring buffer with auto-scroll, level-based highlights, auto-close on
app exit via pidof polling. Known follow-ups:

- **Persist soft filter per-project** — currently in-memory only;
  moving to workspace config lets power users save a preferred
  level or regex.
- **Multi-session view** — one stream at a time today; a second
  device launch stops the first log. If users need to tail two
  apps concurrently, expose multiple views keyed by
  `(serial, bundle)`.
- **Save log to file** — simple `:w` action or a `SaveLog` keymap
  that dumps the rendered buffer to `.nvim/device-log-<ts>.log`.
- **Structured column view** — keep the render compact by default,
  but offer a "full format" toggle that shows PID / proc / domain
  columns aligned.
- **Other modules** — the parser + view are harmony-shaped today
  (hilog format). When cmake `run` output wants the same kind of
  surface, factor the parser into a strategy and reuse view +
  ring buffer.

---

## Disable navigation keymaps in loomworks UI windows

`<C-o>`, `-` (oil.nvim), and similar global keymaps can navigate away
from loomworks status page, config editors, and other UI windows.
Fixed in loomtest explorer — need same treatment in loomworks View/Tree
widget (view.lua, status.lua).

---

## No-tool profile: MSVC auto-detection metadata

When creating a profile without selecting a tool (no cmake kits detected),
cmake picks MSVC automatically. The resulting build is multi-config but
loomworks metadata (cmake_info.multi_config, tool_data.generator) doesn't
reflect this. Investigate why tool detection didn't offer MSVC and why
cmake_info is wrong after configure.

---

## Overseer template references as launch targets

LaunchTarget currently supports module targets (cmake executables) and
command-type configs (loomworks.json launch section). Could also support
referencing overseer task templates (e.g., from VS Code launch.json)
as launch targets.

## Configuration conflict detection

Detect when two configurations share the same output directory (e.g.,
TypeScript outDir). Warn via confirmation dialog before building a
conflicting configuration. Auto-detect from outDir comparison; optionally
allow explicit conflict declaration in loomworks.json.

## Implicit single-config mapping

If a project has exactly one configuration (e.g., TypeScript's "default"),
the configuration_set could omit it — auto-map to the only option.
Reduces loomworks.json verbosity for simple projects.

## Configuration validation

When parsing loomworks.json, validate that configuration_set mappings
reference configurations the module actually knows about. Show warnings
like "ScenePluginTest: 'production' is not a known configuration".

## Optimize redundant npm install

TypeScript configure (npm install) is per-ConfigUnit but npm install is
project-level (shared node_modules). Could deduplicate by making configure
project-level rather than configuration-level.

## ~~Post-build file copy support~~

**Addressed** (feature/deploy-steps). Implemented as deploy steps on launch
configurations — declarative copy steps that ensure build artifacts are
deployed before launch, with freshness tracking. See specification.md
section 9.8.

## TypeScript LSP integration (tsconfig switching)

Similar to clangd integration for cmake: provide factory functions that
route ts_ls/vtsls to the correct tsconfig per profile. Would need a
`typescript.tsconfig` field per configuration in loomworks.json, and a
`ts_ls_root_dir` factory similar to `clangd_root_dir`. Auto-restart
ts_ls on profile switch when tsconfig changes.

Low priority — most TypeScript projects use a single tsconfig.json.
Only needed when profiles map to different tsconfig files (e.g.,
tsconfig.debug.json vs tsconfig.release.json).

## Tool selection when adding second keyed-module type

When adding a project of a *new* keyed-module type (e.g., meson to a
cmake workspace), existing profiles need a tool selection for the new
module type. The multi-tool data model (profile.tools dict) supports
this, but the UI flow for selecting tools per module type during
add-project is not yet implemented. Currently only single-keyed-module
workspaces are fully handled (tool inherited from existing profiles).

## Clear active profile on deletion

When a profile is deleted, the active_profile in loomworks.user.json
should be cleared if it matches the deleted profile. Currently the
profile is removed from cache but user.json still references it,
leaving a dangling active_profile until the user activates something
else.

## Clean directories per configuration

Allow specifying additional directories to delete when cleaning a
configuration. For example, cmake deploy steps copy DLLs and .node files
to `ScenePluginTest/Debug/` — these should be cleaned when the
configuration is cleaned.

Could be defined in loomworks.json per project:
```json
"ScenePluginTest": {
    "typescript": {},
    "clean_dirs": ["${project_path}/Debug", "${project_path}/Release"]
}
```

Variable expansion (${project_path}, ${config_set}) applies. Directories
are deleted during the clean action alongside module clean_tasks.

## Decouple config_key from variant name

Currently `config_key` is derived from `variant + tool_key` (e.g.,
`"Debug:ninja-gcc-12"`). This makes the variant name load-bearing for
identity — renaming a configuration requires rekeying cache entries,
registry slots, and profile configuration arrays.

Ideally, `config_key` would be a stable opaque ID assigned at creation
(e.g., sequential or UUID). The variant name would be purely a display
label. Rename would then be a simple field update with no rekeying.

This would also align with the architectural principle that keys should
not be used for runtime lookups — only direct object references.

## Modules as domain objects + cache deserialization isolation

Modules are currently stateless function tables loaded via `require`.
Making them domain objects would:

1. **Module domain objects** — Workspace owns Module instances. Each
   module owns its Tool registry. `project._module` replaces
   `project.type` string. `tool._module` replaces `tool.mod_type`
   string. Module-specific logic (cmake task generation, info parsing)
   lives on the module object; generic behavior stays in shared code.

2. **Deserialization layer** — The `_sync_*` methods become the only
   place that does key→object resolution. They resolve every string
   reference from cache/config into domain object references, then
   pass fully-resolved data to `_update()`. After deserialization,
   key→object tables are not accessible to domain objects.

3. **No key lookups in domain objects** — `_update()` receives
   pre-resolved references. `_workspace` back-reference either goes
   away or becomes a narrow interface (no registry access). Domain
   objects navigate only via direct references.

This eliminates the remaining string-based lookups: `find_tool(mod_type,
tool_key)`, `mod_type` strings throughout the codebase, and
`_workspace._projects[key]` during `_update()`. Cache format stays
the same (strings on disk, resolved on load). Object identity
preservation and remerge ordering are unchanged.

Entry point: Module domain objects (wrapping existing function tables).

## Built-in sanitizer/tool configuration templates

Provide pre-built abstract mixin configurations for common development
tools: address sanitizer (asan), thread sanitizer (tsan), undefined
behavior sanitizer (ubsan), memory sanitizer (msan). Users inherit from
these mixins to create concrete configs (e.g., `Debug-asan` inherits
`[Debug, asan]`).

Best starting point is the Meson module — Meson has first-class sanitizer
support via `-Db_sanitize=address` etc., so the mapping is clean. For
cmake, sanitizer flags are compiler-specific (`-fsanitize=` for gcc/clang,
`/fsanitize=` for MSVC) and would need compiler detection to generate
correct options. Defer cmake sanitizer templates until compiler-aware
option generation is available.

## Profile/variable persistence lost after task failure

Observed: after creating a profile or adding variables and triggering a
configure/launch that fails, the data may disappear from user.json or
loomworks.json on a subsequent save. Possibly related to the stuck
operation / remerge interaction, or a save triggered by the failure
path overwriting with stale data. Error logging added to `_save_user`
(2026-04-02) to help diagnose if it recurs.

## Variable/deploy discoverability and documentation in UI

The variable system and deploy steps lack in-editor documentation.
Users need help text or descriptions for:
- Available built-in variables (${workspace_root}, ${build_dir}, etc.)
  and what they expand to
- The difference between ${variant} (cmake variant) and ${configuration}
  (config name from profile mapping)
- Source path is relative to build dir (for path type)
- ${project_path} is relative, use ${workspace_root}/${project_path}
  for absolute
- Variable type meanings (string vs path — path enables segment editor)
Could add tooltips, help text in editors, or a help dialog.

---

## ~~Rename-back shows entry in both profiles and orphaned sections~~

**Fixed** (fix/rename-orphan-accumulation). Root cause: rename used
`_rebuild_profile_projects_for` which destroyed and recreated domain
objects. Fix: pure in-place mutation — Configuration, Profile, ConfigUnit
all keep identity. Old BuildDir orphaned as domain object; rename-back
adopts it. Introduced BuildDir domain object, removed `_last_raw_cache`.

---

## Graceful degradation for external dependencies

Current hard dependencies: **overseer** (build/launch), **snacks** (picker,
explorer window). Soft: fidget (progress), nvim-dap (debug), lualine
(status component).

Issues to address:
- **fidget**: build/deploy progress uses fidget exclusively — if not
  installed, progress is silent. Should fall back to `vim.notify` or
  a minimal echo.
- **snacks**: used for `vim.ui.select`-style pickers and the loomtest
  explorer window (`Snacks.win`). Should fall back to `vim.ui.select` /
  `vim.ui.input` for pickers. Explorer window needs snacks or an
  alternative (floating window API directly).
- **overseer**: core dependency, hard to remove. Document as required.
- Audit all `require()` calls to external modules for pcall guards.

---

## codelldb: no local variables for dynamically loaded .node modules

**Symptom**: When debugging a Node.js native addon (.node shared library)
via codelldb (either launching node directly or attaching), breakpoints
and line stepping work but local variables are not shown in scopes.

**Root cause**: LLDB's PDB plugin crashes when trying to resolve symbol
addresses for dynamically loaded modules. `target symbols add` loads
the PDB but hits assertion failure: `obj_load_address != LLDB_INVALID_ADDRESS`
in `SymbolFilePDB::InitializeObject`. LLDB can't determine the load
address of the .node module in memory.

**Findings**:
- PDB files are present and well-formed (function symbols + line tables load)
- `image dump symfile` shows empty Types/Compile units before process runs
- Build uses clang `-g -Xclang -gcodeview` producing CodeView/PDB format
- Standalone cmake executables debug fine with full locals
- Issue is specific to shared libraries (.node/.dll) loaded at runtime
- cppvsdbg (Microsoft's native debugger) would handle this but is
  licensed for VS Code only

**Potential fixes**:
- Switch to DWARF debug info (`-gdwarf` instead of `-gcodeview`) — LLDB
  handles DWARF better for shared libraries
- Wait for LLDB PDB plugin improvements (active development area)
- Structured debug entry with symbol search paths (future loomworks feature)

---

## Plugin-based module registry

Currently modules are hardcoded in `modules/init.lua`. Third-party plugins
should be able to register modules by placing files in `lua/loomworks/modules/`
on the runtimepath. Auto-discovery would scan all rtp entries, validate the
module interface (`M.id`, `M.detect`, `M.info`, `M.tasks`), and register
valid modules alongside built-ins. Needs: interface validation, error handling
for broken modules, load order guarantees, potential config for disabling
specific modules.

---

## Profile-level SDK integration (design ready, not implemented)

**Problem**: Currently profiles select tools per module type independently.
Cross-compilation requires all modules to use the same SDK. A cmake project
and a harmony project in the same profile should both use the same OHOS SDK.

**Design decisions**:

1. **SDK is a profile-level selection**, not per-module. Profile has:
   - Configuration set
   - SDK (optional domain object reference, nil = host build)
   - Tool overrides (for modules SDK doesn't cover)

2. **SDK provides tools to all modules it supports**. Core asks
   `sdk:query(module.id)` for each module — no module/SDK-specific logic
   in core. If SDK returns nil for a module, that module uses host tools.

3. **No fallback guessing**. If no tool mapping exists for a module in a
   profile, the profile is flagged "incomplete" rather than silently
   creating a default. No automatic Visual Studio / default compiler
   fallbacks. User must explicitly select.

4. **Profile name includes SDK**. "Debug:ohos" or "Debug:ninja-clang-18".
   SDK profiles are distinct from host profiles.

5. **Profile creation flow**: pick config set → pick "Host" or an SDK →
   if host, pick cmake kit (existing flow). If SDK, tools derived
   automatically from SDK capabilities.

6. **Serialization**: profile stores `sdk_key` string. Deserialization
   resolves to SDK domain object via workspace. If SDK not found,
   profile is incomplete.

7. **Core stays generic**: no `if sdk_type == "ohos"` anywhere. Core
   iterates modules × SDKs via query interface.

**Implementation needed**:
- Profile domain object: add `_sdk` reference field
- Profile creation UI: SDK picker step
- Tool resolution: SDK-first, then module detection, then incomplete
- Remove all tool fallback guessing from modules
- Serialization: sdk_key in user.json profiles section
- Status page: show SDK on profile, incomplete state

