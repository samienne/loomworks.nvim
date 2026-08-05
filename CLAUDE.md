# loomworks.nvim — Project Context for Claude

## Authoritative Documents

- **[specification.md](specification.md)** — **Index** over the core
  behavioral specification. Defines *what* the system does at the contract
  level: data model, state machines, module/LSP/DAP/SDK/device contracts,
  invariants. Contains no module/tool/SDK names in normative prose. The
  normative sections are physically partitioned into topic files under
  [`spec/core/`](spec/core/) (section numbers keep their original global
  values — they are NOT local to each file); `specification.md` holds the
  preamble, routing tables, and §15 Invariants inline, plus the
  §-range → file table. Core topic files:
  - [`spec/core/data-model.md`](spec/core/data-model.md) — §1 Data Model
  - [`spec/core/three-file-model.md`](spec/core/three-file-model.md) — §2 Three-File Model
  - [`spec/core/state-lifecycle.md`](spec/core/state-lifecycle.md) — §3–§7 state machine, profile lifecycle, task execution, UI, events
  - [`spec/core/module-interface.md`](spec/core/module-interface.md) — §8 Module Interface
  - [`spec/core/integrations.md`](spec/core/integrations.md) — §9–§14 LSP, SDK, device, overseer, auto-load, commands
  - [`spec/core/headless.md`](spec/core/headless.md) — §16 Headless / Standalone
- **[spec/](spec/)** — Per-implementation specs that fulfil the core
  contracts:
  - [`spec/ui.md`](spec/ui.md) — status page, highlights, winbar
  - [`spec/modules/`](spec/modules/) — cmake, meson, shell, typescript
  - [`spec/integrations/lsp/`](spec/integrations/lsp/) — clangd, …
  - [`spec/integrations/debug/`](spec/integrations/debug/) — codelldb,
    cppdbg, pwa-node, …
  - [`spec/sdks/`](spec/sdks/) — cpp_compiler, …
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Implementation architecture.
  Defines *how* the system is built: layers, object model, data flow,
  file layout.
- **[README.md](README.md)** — User-facing documentation. Setup, API,
  examples.

When designing a new feature, pull in only the spec files relevant to the
change. The "Where does this change go?" table at the top of
specification.md guides which files apply for a given task.

Do NOT duplicate content from these files in CLAUDE.md. Refer to them
instead.

## Spec-First Development Workflow

**Before implementing any change that contradicts what is written in
specification.md or ARCHITECTURE.md, STOP.** Propose the specification change
first, explain the reasoning, and wait for approval. Only after the spec
change is approved should you update specification.md and then implement the
code change.

This prevents the spec and implementation from diverging. The cycle is:

1. Identify what needs to change (spec vs current behavior)
2. Propose a spec amendment (show the diff or describe the change)
3. Wait for user approval
4. Update specification.md (and ARCHITECTURE.md if architecture changes)
5. Implement the code change
6. Update or add tests

For changes that are clearly *within* the existing spec (bug fixes, adding
tests, refactoring without behavior change), skip steps 1-4 and implement
directly.

## Branch Workflow

All changes go through branches — never commit directly to master.

### Plan first, then execute

Before starting implementation, propose a plan and wait for approval. This
applies to non-trivial changes — simple one-line fixes or obvious corrections
can proceed directly.

### Commits

Do not create commits automatically. Only commit when the user explicitly
asks. It is fine to suggest "should we commit this?" at natural stopping
points.

### Creating branches

- **Feature branches**: `feature/<short-name>` — new functionality or enhancements
- **Bugfix branches**: `fix/<short-name>` — bug fixes
- Branch from master. Multiple commits on the branch are fine.

### Mid-feature bugfixes

If a bug is discovered while working on a feature branch:

1. Switch to master, create `fix/<name>`, fix and merge `--no-ff`
2. Switch back to the feature branch, rebase onto updated master
3. Resolve any conflicts

### Pre-merge checklist (mandatory)

Before merging ANY branch to master, verify:

1. **specification.md** — all behavioral changes are reflected
2. **ARCHITECTURE.md** — any structural changes are documented
3. **README.md** — user-facing changes are covered
4. **No discrepancies** — the three documents agree with each other and with
   the code being merged
5. **Type annotations** — all LuaCATS `@class`/`@field` annotations affected
   by the changes are up to date. No stale fields, no missing new fields.
   Domain object annotations live in the implementation file, not types.lua.
6. **Comments** — comments near changed lines are still accurate
7. **Tests pass** — `make test`

**Do not merge if documentation is out of sync.** Fix the docs first, then
merge. If the user does not ask for this check, remind them before merging.

### Bugfix workflow

When a bug is encountered, reproduce it with an integration test first,
then fix it. This builds real-world scenarios into the test bank and
prevents regressions.

1. Write a failing integration test that reproduces the bug
2. Verify it fails for the right reason
3. Fix the bug
4. Verify the test passes

### Merge format

Use `git merge --no-ff` with a summary commit message that describes *what*
and *why* — not a dump of individual branch commits.

## What this is

A Neovim workspace management plugin. Provides project structure information
to other plugins (LSP configs, overseer, DAP). Non-invasive — collaborators
don't need to know it exists. Read-only toward project files.

The plugin lives at `C:/src/nvim-plugins/loomworks.nvim` and is loaded via the
owner's Neovim config (C:/Users/samie/AppData/Local/nvim, branch `loomworks`),
which auto-loads every subdirectory of `C:/src/nvim-plugins` as a lazy.nvim dev plugin.

## Key Concepts (quick reference)

- **Workspace** — domain container class, defined by `loomworks.json`. Owns all
  registries, business logic, and domain objects
- **project** — sub-component with a type (cmake, meson, typescript)
- **configuration** — build variant within a project (Debug, Release)
- **configuration_set** — cross-project mapping of configurations
- **tool** — module-specific toolchain (cmake: generator+compiler)
- **profile** — fully resolved buildable unit (configuration_set + tool)
- **ConfigUnit** — single source of truth for (project_key, config_key) runtime state

See specification.md sections 1.1–1.7 for full definitions.

## Deletion Safety (mandatory review)

Any change that touches deletion logic (rm_rf, rm_rf_async, _run_deletion,
_validate_build_dir, delete_cached_configs, reset_cached_configs,
execute_deletion, clean_*, delete_*, nuke_cache) **must** be reviewed for
directory safety before merging:

1. **Boundary check**: path prefix comparisons must include a trailing `/`
   separator to prevent prefix collisions (`/root` must not match
   `/roots/...`). Use the pattern: `path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"`
2. **Nil/empty paths**: build_dir can be nil — always check before passing
   to deletion functions.
3. **Cache as source of dirs**: build directories come from
   `loomworks.cache.json` which could be corrupted. Never trust cache paths
   without validation.
4. **Crash safety**: cache must reflect "unknown" state before async
   deletion starts. Cache entries are only removed after confirmed success.
5. **Two safety scopes**: `_validate_build_dir` checks against workspace
   root (build dirs can be anywhere under it). `_safe_nvim_path` checks
   against `root/.nvim/` (used by nuke_cache only).
6. **Shared dir protection**: `_build_dir_refs` tracks which cache keys
   reference each build dir. `_run_deletion` skips rm-rf when remaining
   refs > 0 after subtracting the batch being deleted.

## Implementation Notes

These are implementation-specific details not covered by the spec or architecture:

- **Workspace as domain container**: `Workspace` class owns all registries
  (projects, profiles, config sets, config units, profile projects, tools,
  build dirs) and all business logic (sync, merge, cache, operations, deletion,
  task tracking, tool scanning). Domain objects store a `_workspace` back-reference.
- **Workspace lifecycle**: `Workspace:on(event, handler)` is the registration
  helper for any subscriber that should detach on workspace swap or
  `:LoomworksReload` — i.e. any subscriber that mutates workspace state or
  closes over a workspace object. Plugin-global subscribers (UI re-render,
  lualine) keep using `events.on` directly. `Workspace:teardown` walks
  `_event_handlers`, stops the file tracker, cancels in-flight overseer
  tasks, and drops `_build_dir_locks`. Core calls it on workspace swap
  (cwd change) and shutdown. The dev hatch `:LoomworksReload`
  (`lua/loomworks/reload.lua`) calls `core:shutdown()` then delegates to
  `lazy.reload` for `package.loaded` clearing + config re-execution.
  Overseer task_tracker subscribers are not detached — they fail fast
  against a torn-down workspace; acceptable leak for a dev-only feature.
- **Core is infrastructure-only**: `Core.new(deps)` with injectable
  dependencies for testing. Owns I/O, modules, events, file tracking, setup.
  Thin delegation wrappers forward to Workspace so init.lua callers continue
  to work via `core:method()`.
- **Workspace mutation methods**: `config_editor.lua` is no longer used at
  runtime — Workspace has its own mutation methods for adding/removing
  projects, configuration sets, etc. `rename_project_configuration` does
  atomic rename with config set, cache, and profile propagation. All
  mutations write to user.json (working copy). `publish()` writes published
  items to loomworks.json on explicit `:w`.
- **Publish/working-copy model** (spec §2.4): user.json is the live working
  state and runtime source of truth; loomworks.json is a published snapshot
  regenerated on `:w` (never read at runtime). Each publishable item carries
  one `_intent` field with three values: `local` (user.json only), `shared`
  (loomworks.json only — cat-3 / dimmed), `local+shared` (both). Intent is
  **sticky**: assigned once at item creation, preserved across remerges
  thereafter; only explicit user action changes it. Constructors set
  `_intent = nil`; `data_model.refresh` falls through to a default-from-presence
  computation only when no prior value exists, so file-presence changes don't
  silently flip the user's wish. `_serialize_user` persists intent overrides
  whenever they differ from the current default; `_save_user` is called after
  every external file change so stickiness survives Neovim restarts.
  Effective intent (transitive): `Workspace:_publishable_to_shared()` walks
  config-set → projects/configs and (published) profile → set → projects/configs
  to compute the closure of items that must reach loomworks.json — used by
  `_serialize_config` and `_serialize_project_shared`. Implicit cascade-on-use:
  `_mark_user_owned` lives on Project/Configuration/ConfigurationSet/Profile
  and is called by mutation paths (`Profile:activate`,
  `ConfigurationSet:update_mapping`, `add_configuration_set`,
  `Project:save_configuration`) so user.json self-containment holds without
  manual pinning. Removed-upstream indicator: `_on_file_changed` snapshots the
  old baseline before remerge, then `_mark_removed_upstream` flags items that
  were in old baseline but not new (and have effective `local+shared`); flag
  clears on `publish()`, `revert_one()`, or item deletion. `+` indicator
  computed by comparing published state against `_shared_baseline`. `:w` on
  the status buffer calls `Workspace:publish()` (full regen);
  `:e!` calls `Workspace:revert_to_baseline()` (data-preserving — locally-added
  items demote to `local`); BufReadCmd-driven, Vim's E37 handles `:e` refusal
  on dirty buffer. Per-item resolution: `publish_one(item)` writes a partial
  loomworks.json (preserves untouched entries), `revert_one(item)` resets a
  single item to baseline. `P` key cycles intent through the three values.
  Per-config merge: projects from both files merge at the
  configuration/launch/variable level (user wins per-key). External
  loomworks.json changes auto-sync items whose content matched the old
  baseline; diverged items keep user version.
- **workspace_view.lua**: View-model layer between UI and Workspace. Owns
  orchestration logic (add/remove project pipelines, tool detection caching,
  upgrade/downgrade previews, config set candidates). UI files call
  workspace_view; workspace_view calls Workspace atomic mutations.
- **Multi-tool profile model**: CachedProfile stores `tools` dict keyed by
  module type (e.g. `{ cmake = { key, data, label } }`), not flat fields.
  Profile objects expose `profile.tools` dict and `profile:tool_for(mod_type)`.
  Cache version 6. Unified rename via `compute_profile_renames(transform)` +
  `apply_profile_renames(renames, transform)`.
- **Bootstrap**: `create_workspace_config()` is a static function on the
  workspace module for creating a new `loomworks.json` on disk (no Workspace
  instance needed).
- All objects identity-preserving across refreshes via `_apply(data, ctx)`;
  `_removed` flag for dead references.
- **`_apply(data, ctx)`**: unified constructor/update method. Receives a data
  table and deserialization context. Resolves keys to references via ctx. Sets
  data fields. Never touches runtime fields. Returns `true` or `nil, error`.
  Same code path for new objects (constructor calls `_apply`) and updates.
- **BuildDir domain object** (`build_dir.lua`): represents a physical build
  directory with cached state (configured, built, failed). Separate from
  ConfigUnit (user intent). ConfigUnit references a BuildDir via `_build_dir`.
  Orphaned BuildDirs have state but no ConfigUnit pointing to them. Created
  during `sync_build_dirs()` from cache entries. Workspace owns `_build_dirs`
  array (all BuildDirs including orphaned). No raw cache data retained after
  deserialization — BuildDir objects ARE the source of truth for build state.
- **First-class fields**: ConfigUnit stores `state_value`, `build_dir_value`,
  `last_configured`, `last_built`, `cmake_info`, `_variant`, `_tool_key`,
  `_tool_data` as individual fields, plus `_build_dir` (BuildDir reference).
  `serialize()` produces cache-shaped table on demand. No `_cached` bag.
  ConfigUnit↔cache matching anchors on the stable `(project_key, config_key)`
  identity (`Workspace:find_cache_entry_for`), never a recomputed build-dir
  path — the unit adopts the persisted entry's build_dir, so a volatile path
  segment (e.g. a cache entry written without tool_data) can't orphan a built
  entry and force a needless reconfigure.
- **DataModel** (`data_model.lua`): deserialization orchestrator. Receives raw
  file data + current domain object arrays (never accesses Workspace directly).
  Builds deserialization context with resolver methods (`ctx:project(key)`,
  `ctx:tool(mod_type, key)`, etc.). Returns new arrays or error.
- **Refresh vs mutation**: `refresh()` is only for external file changes
  (FileTracker → DataModel → swap arrays). Mutation methods update domain
  objects in place and call `_save_cache()` to persist. No round-trip.
- **Workspace arrays**: `_modules`, `_projects`, `_config_sets`, `_profiles`,
  `_config_units`, `_profile_projects`, `_build_dirs` are arrays after refresh. Runtime
  callers iterate with `pairs()` or use `find_*` helpers (`find_project(key)`,
  `find_profile(key)`, `find_config_set(name)`, `find_module(mod_type)`).
- `types.lua` defines LuaCATS type annotations for serialization data shapes,
  interfaces, and aliases. Domain object `@class` annotations live in the
  implementation file (e.g., `loomworks.ConfigUnit` in config_unit.lua).
  Never duplicate domain object classes in types.lua.
- init.lua is thin facade; core.lua is infrastructure; status.lua is pure rendering
- Progress tracking: ninja parser, operation timing, weighted aggregate
- Atomic writes on Windows: rename can fail if file is open; implement retry with short sleep
- **Windows path normalization**: `deps.normalize` lowercases on Windows (`vim.fn.has("win32")`).
  All path comparisons (build dir refs, locks, stray detection, prefix checks) use normalized
  (lowercased) paths. Cached `build_dir` values retain original casing for display.
- clangd auto-reloads when compile_commands.json changes on disk — no explicit restart needed
- **Build dir reverse index**: `_build_dir_refs` maps normalized build dir → set
  of cache keys. Rebuilt in `_sync_build_dir_refs()` during remerge. Used by
  deletion safety (skip rm-rf of shared dirs) and UI hints ("shared" indicator).
- **Build dir operation queue**: `_build_dir_locks` provides per-build-dir
  exclusive/shared locks with FIFO queue. Exclusive for configure/delete/clean,
  shared for build. `acquire_build_dir_lock()` in overseer.lua before task start,
  `release_build_dir_lock()` in task_tracker on complete/dispose (idempotent).
  Prevents concurrent operations from corrupting shared build directories.
- **Module domain object** (`module.lua`): wraps a stateless module function
  table (cmake.lua, meson.lua, typescript.lua) as a per-workspace domain object.
  Owns the Tool registry for its module type. No `_workspace` back-reference.
  `Project._module` replaces `project.type` string for module identity.
  Created during `_sync_modules()`, first step of remerge.
- **Tool domain object** (`tool.lua`): represents a toolchain (ninja-gcc-12,
  msvc-17-2022). Owned by `Module._tools` registry, keyed by `tool_key`.
  `Tool._module` references the owning Module. Created from detection results
  + cached tool_data. Non-keyed modules (typescript) have a single
  default Tool with nil key. Domain objects carry `_tool` references.
  Accessors: `unit:tool_object()`, `profile:tool_object_for(module)`,
  `pp:tool_object()`.
- **Configuration domain object** (`configuration.lua`): represents a build
  variant (Debug, Release, Debug-asan). Owned by `Project._configurations`,
  created from module.info() output + user overrides + cache enrichment.
  Separates generic fields (name, variant, inherits, options) from
  module-specific data (`module_config`). Inheritance uses Configuration
  references. `_source_missing = true` for configs that exist only in cache
  (no live module source). Domain objects carry `_configuration` references.
  Accessors: `unit:configuration()`, `pp:configuration()`,
  `cs:configuration(project)`, `pp:variant_name()`.
- **ProfileProject stores `_configuration`** (Configuration object), not a
  variant string. `pp:variant_name()` returns the name string for callers
  that need it. `find_config_unit`/`ensure_config_unit` accept Configuration
  objects (not variant strings).
- **Cache-sourced Configuration enrichment**: `Project._sync_configurations()`
  enriches `_configurations` from `cached_configurations` so that every variant
  in cache always has a Configuration object. Source-missing configs get
  `_source_missing = true`; the flag clears when the source reappears.
- **Deploy steps** (`deploy.lua`): declarative copy steps on launch configs.
  `deploy` dict in launch config keyed by destination path template, values
  are source descriptors `{ project, target|path, configuration? }`. Resolved
  within active profile context. Freshness tracked in `_deploy_records` dict
  on Workspace (serialized to `cache.deploy_state`). Copies only when source
  identity (config unit) or mtime changes. Cleanup on config deletion.
  LaunchTarget.deploy() executes steps between build and launch.
- **Project variables** (`variables.lua`): user-defined variables declared
  at project level `{ name → { type, default } }`, overridden per
  configuration via inheritance chain. Types: `string`, `path`. Resolution
  uses Configuration object references (`_inherits` array), not name
  strings. Provenance tracked as Configuration object reference (`source_config`).
  Values can reference built-in variables only (no cross-variable refs).
  Reserved names prevent collision with built-ins. Expanded in
  `expand.launch_context()` after built-in variables (two-pass: variable
  value expanded using built-in context). Path-typed variables appear in
  deploy editor segment picker.
- **Test integration** (spec §8.9): neotest adapter bridges ConfigUnit's test
  interface to neotest. TestUnit (`test_unit.lua`) is the interface; CTestUnit
  (`test_units/ctest.lua`) wraps ctest. GTest helper (`gtest.lua`) handles
  framework detection, source scanning, XML parsing. ConfigUnit delegates to
  TestUnits created lazily by module factory (`create_test_unit`). cmake
  file-api `parse_targets` extracts source files per target for test→source
  mapping. Neotest adapter uses pcall on all methods (nio coroutine hangs on
  errors), avoids `vim.fn` calls (deadlock in nio), deduplicates
  `discover_positions` calls (Windows path format mismatch), and caps
  per-line entries (parameterized test merge performance).
- **loomtest** (`lua/loomtest/`): test-first test explorer, independent from
  loomworks. Core: explorer (Snacks.win tree), runner (overseer + streaming
  + gtest XML), signs (gutter), inline (extmark virtual text + vim.diagnostic).
  `loomworks_adapter.lua` bridges ConfigUnit/TestUnit to loomtest's TestAdapter
  interface. Auto-builds test targets before execution. Timestamp-based
  staleness clears only changed files' results. See LOOMTEST.md for full spec.
  Explorer uses `relative = "win"` (splits within code area, not full frame)
  and `winfixbuf = true` (prevents buffer hijacking).
- **DAP integration** (`lua/loomworks/debug.lua`): single gateway to nvim-dap.
  `debug.run(spec, callbacks)` constructs DAP config with adapter-specific
  `extra` fields and calls `dap.run()`. Supports `request = "attach"` with
  `attach_pid` for multi-adapter sessions. Checks adapter availability before
  launch (shows Mason install hint, returns false). Language-based adapter
  resolution: `resolve_adapter(workspace, language)` reads `user.json`
  `debug.adapters` mapping with fallback defaults (`c++` → codelldb,
  typescript → pwa-node). Backwards-compatible with legacy module type keys
  via `MODULE_TO_LANGUAGE` mapping. Modules declare `languages` field
  (e.g., cmake.languages = {"c++"}). Module domain object exposes
  `primary_language()`. `on_pid` callback captures PID from `runInTerminal`
  response for multi-adapter attach. `known_languages()` returns all known
  languages. Status page Debug Adapters section shows languages not module
  types. Launch config `debug` field: array of language strings, first =
  primary (launch), rest = attach to same PID. Launch editor UI for
  adding/removing/reordering debug languages. `setup()` registers default
  keymaps including debug variants (opt-out with `keys = false`).
- **Session tracking** (`lua/loomworks/session_tracker.lua`): unified
  lifecycle manager for overseer launches and dap debug sessions.
  `start(target, mode)` shows confirmation dialog if a session is active,
  then runs build → deploy → execute chain with fidget progress. Debug
  fidget spans from build start to `event_initialized`. `stop()` terminates
  dap with `hierarchy = true` (kills debuggee process). Auto-cleans tracked
  run on session end. init.lua delegates `launch_target()`, `debug_target()`,
  `stop_target()` to session_tracker.
- **Device domain object** (`device.lua`): represents a physical or emulated
  deployment target. Identified by serial string. Fields: serial, display_name,
  provider (module id), state (online/offline), properties. Runtime-only
  (not persisted to cache). Workspace owns `_devices` dict (serial → Device).
  Discovered on demand via module's `list_devices()`. Profile stores optional
  `_device_serial` (persisted in user.json). Device interface on modules:
  `has_devices` (boolean), `list_devices`, `device_targets`, `device_install`,
  `device_launch`, `device_log`, `resolve_artifact`, `resolve_launch_info`.
  LaunchTarget has third type: device targets (descriptor field `device_target`).
  Session tracker extends chain: build → deploy → device-install → device-launch
  for targets where `requires_device()` is true. Always reinstalls (no freshness).
- **Error handling**: on deserialization error (structurally invalid data),
  Workspace cancels all tasks, enters error state, status page shows nuke
  option. Orphaned objects (project removed from config but cache still
  references it) are NOT errors — they are handled gracefully.
- **Repo-local launcher + version pin** (spec §16.21–16.24): `lw bootstrap`
  commits `lw.sh`/`lw.cmd`/`lw.pin` so a repo runs a pinned, verified `lw` with
  no prior install. `boot/pin.lua` is pure (parse/serialize `lw.pin`, asset
  selection via `HOST_ASSETS`, `decide{}` redirect action); `boot/bootstrap.lua`
  authors the pin from a release's SIGNED `SHA256SUMS` and holds the launcher
  templates; `boot/update.lua` adds `ensure_host_binary` + `ensure_version`
  (bundle → repo-local `.nvim/cache/lua-<ver>/`). `main.lua` provisions on the
  `LOOMWORKS_PINNED` sentinel and redirects workspace ops (build/run/test/clean/
  configure) to the pinned release. Invariants: fixed origin (user-overridable
  only via `LOOMWORKS_RELEASE_URL`), version+hash pin never a URL, mandatory
  hash even under `--insecure`, global host never execs the repo scripts.
  Escapes: `--no-pin`, `LOOMWORKS_LW`, dev source. Launcher scripts copy (not
  curl) for a local-dir mirror, matching `boot.download`.

## Plugin API versioning

`lua/loomworks/api_versions.lua` holds the strict-equality version
constants for the module + SDK plugin interfaces (`module = 1`,
`sdk = 1`). Module / SDK files declare `M.api_version = N` matching;
the registry's `M.get(id)` refuses to load mismatched plugins with a
clear `vim.notify` error. No backwards compatibility — bump core's
constant when the contract surface changes, and every plugin
shipping that interface category bumps in lockstep. See
[specification.md §8.0](spec/core/module-interface.md) for the bump policy.

Unknown-type / rejected-module projects in `loomworks.json` are
preserved verbatim through load → in-memory model → serialize, so
data is never lost when a plugin is missing or version-mismatched
(see specification.md §8.0).

## v1 Scope

**V1 modules:**
- `cmake` — full implementation
- `meson` — full implementation (detection, default Debug/Release/RelWithDebInfo
  configs mapping to buildtype, setup+compile+clean tasks, introspect-based
  parse_targets and get_options, clangd via lsp_configs with auto-generated
  compile_commands.json, cross-file machine file support, per-compiler keyed
  tools that pin CC/CXX and prepend compiler bin dir to PATH, loomtest
  integration via MesonTestUnit using `meson introspect --tests` + gtest
  probing with jump-to-test via `target_sources`)
- `shell` — generic shell-command runner. Manually-declared projects with
  user-supplied configure/build/clean commands and a build_dir template,
  resolved through the variable system. Forwards compile_commands.json
  location to clangd via lsp_configs. No auto-detect, no tools, no
  staleness check, no targets/tests — see spec/modules/shell.md.
- `typescript` — shim (shows project exists, no build functionality)

Module-specific implementations that target a particular platform/SDK
(e.g., HarmonyOS / OpenHarmony via `loomworks-module-ohos.nvim`) ship
as separate plugins and are not part of the core repo.

**Deferred (not in v1):**
- DAP, test integration beyond ctest, sub-workspaces, cross-project
  dependencies, auto-detection, named toolchains — see specification.md for
  interface stubs where applicable.
