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
5. **Tests pass** — `make test`

**Do not merge if documentation is out of sync.** Fix the docs first, then
merge. If the user does not ask for this check, remind them before merging.

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
- **project** — sub-component with a type (cmake, ets, typescript)
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
  (projects, profiles, config sets, config units, profile projects, tools) and
  all business logic (sync, merge, cache, operations, deletion, task tracking,
  tool scanning). Domain objects store a `_workspace` back-reference.
- **Core is infrastructure-only**: `Core.new(deps)` with injectable
  dependencies for testing. Owns I/O, modules, events, file tracking, setup.
  Thin delegation wrappers forward to Workspace so init.lua callers continue
  to work via `core:method()`.
- **Workspace mutation methods**: `config_editor.lua` is no longer used at
  runtime — Workspace has its own mutation methods for adding/removing
  projects, configuration sets, etc. `rename_project_configuration` does
  atomic rename with config set, cache, and profile propagation.
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
- All objects identity-preserving across remerges via `_update()`; `_removed` flag for dead references
- `types.lua` defines LuaCATS type annotations (data shapes, not runtime code)
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
  table (cmake.lua, ets.lua, typescript.lua) as a per-workspace domain object.
  Owns the Tool registry for its module type. No `_workspace` back-reference.
  `Project._module` replaces `project.type` string for module identity.
  Created during `_sync_modules()`, first step of remerge.
- **Tool domain object** (`tool.lua`): represents a toolchain (ninja-gcc-12,
  msvc-17-2022). Owned by `Module._tools` registry, keyed by `tool_key`.
  `Tool._module` references the owning Module. Created from detection results
  + cached tool_data. Non-keyed modules (ets, typescript) have a single
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
- **Domain object references coexist with string fields**: ConfigUnit carries
  both `_tool`/`_configuration` (domain object refs) and `tool`/`variant`
  (string/table fields from cache). String fields are backward-compatible
  aliases — new code should use accessor methods.

## v1 Scope

**V1 modules:**
- `cmake` — full implementation
- `ets` — shim (shows project exists, no build functionality)
- `typescript` — shim (shows project exists, no build functionality)

**Deferred (not in v1):**
- Meson module, DAP, test integration, sub-workspaces, cross-project
  dependencies, auto-detection, named toolchains — see specification.md for
  interface stubs where applicable.
