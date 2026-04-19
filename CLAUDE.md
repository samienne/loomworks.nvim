# loomworks.nvim — Project Context for Claude

## Authoritative Documents

- **[specification.md](specification.md)** — Behavioral specification. Defines
  *what* the system does: data model, state machines, UI behavior, invariants.
  This is the single source of truth for behavior.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Implementation architecture. Defines
  *how* the system is built: layers, object model, data flow, file layout.
- **[README.md](README.md)** — User-facing documentation. Setup, API, examples.

Do NOT duplicate content from these files in CLAUDE.md. Refer to them instead.

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
- **project** — sub-component with a type (cmake, harmony, typescript)
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
  state; loomworks.json is a published snapshot. Each publishable item
  (project, config, config set, profile) has `_published` (should appear in
  loomworks.json) and `_in_user_json` (has data from user.json) flags.
  `_published` defaults from shared baseline presence; non-default values
  persisted in user.json `published` dict. Modified indicator (`+`) computed
  by comparing published state against `_shared_baseline`. `:w` on the status
  buffer calls `Workspace:publish()`. `P` key toggles publish. Per-config
  merge: projects from both files merge at the configuration/launch/variable
  level (user wins per-key). External loomworks.json changes auto-sync items
  that were synced with the old baseline.
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
  table (cmake.lua, harmony.lua, typescript.lua) as a per-workspace domain object.
  Owns the Tool registry for its module type. No `_workspace` back-reference.
  `Project._module` replaces `project.type` string for module identity.
  Created during `_sync_modules()`, first step of remerge.
- **Tool domain object** (`tool.lua`): represents a toolchain (ninja-gcc-12,
  msvc-17-2022). Owned by `Module._tools` registry, keyed by `tool_key`.
  `Tool._module` references the owning Module. Created from detection results
  + cached tool_data. Non-keyed modules (harmony, typescript) have a single
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
- **Test integration** (spec §9.9): neotest adapter bridges ConfigUnit's test
  interface to neotest. TestUnit (`test_unit.lua`) is the interface; CTestUnit
  (`test_units/ctest.lua`) wraps ctest. GTest helper (`gtest.lua`) handles
  framework detection, source scanning, XML parsing. ConfigUnit delegates to
  TestUnits created lazily by module factory (`create_test_unit`). cmake
  file-api `parse_file_api` extracts source files per target for test→source
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
- **Error handling**: on deserialization error (structurally invalid data),
  Workspace cancels all tasks, enters error state, status page shows nuke
  option. Orphaned objects (project removed from config but cache still
  references it) are NOT errors — they are handled gracefully.

## v1 Scope

**V1 modules:**
- `cmake` — full implementation
- `harmony` — full implementation (DevEco/SDK detection, hvigor build pipeline,
  product×target×ABI configurations, external build dirs, SDK clangd via
  native_build_info, cmake_env passthrough)
- `typescript` — shim (shows project exists, no build functionality)

**Deferred (not in v1):**
- Meson module, DAP, test integration, sub-workspaces, cross-project
  dependencies, auto-detection, named toolchains — see specification.md for
  interface stubs where applicable.
