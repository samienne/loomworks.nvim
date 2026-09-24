# loomworks.nvim Architecture

This document describes *how* the system is built — layers, component
responsibilities, dependency rules, and file organization. For *what* the
system does (data model, state machines, UI behavior, invariants), see
[specification.md](specification.md).

---

## System Diagram

```
                      plugin/loomworks.lua
                  :LoomworksInit  :LoomworksInfo
                             |
                       init.lua  ◄── public API facade (singleton Core)
                             |
                         core.lua  ◄── infrastructure: I/O, deps, setup,
                             |         validation, nuke_cache, project_for_buf
                             |         Thin delegation wrappers → Workspace
                             |
                       workspace.lua
                      Workspace class
                      Domain container
                             |
          +------------------+------------------+------------------+
          |                  |                  |                  |
    file_tracker.lua      merge.lua         events.lua       io.lua
    uv.fs_poll-based      three-file        on/off/emit      read_file
    watches 3 files       merge into        listener         write_atomic
    delivers content      ActiveSet         system           rm_rf
                             |
                     +-------+------+
                     |       |      |
                  config   user   cache
                  .lua     .lua   .lua
                  parse    parse  parse
                  valid    save   save
                           load   load
          |
    ======|================================================
          |           Disk (workspace root)
          |
      loomworks.json
      .nvim/loomworks.user.json
      .nvim/loomworks.cache.json
      .nvim/loomworks.health.json
      .nvim/build/...

                       workspace.lua (Workspace)
                             |
     +-------+----+----------+----------+-----------+
     |       |    |                     |           |
 tool.lua  cfg   configuration  config_unit.lua   profile.lua   project.lua
  Tool    _set    .lua          Runtime state     Profile +      Project
  domain  .lua    Configuration per (proj,cfg)    ProfileProject  + Config[]
  object  ConfigSet domain obj  synced + lazy     objects         objects
          |
          +-- progress/init.lua + ninja.lua
              Parser registry for build output

                    init.lua / core.lua
                             |
          +------------------+------------------+
          |                  |                  |
    overseer.lua         lsp.lua           fidget.lua
    Template provider    clangd cmd/root   fidget.nvim
    + task launching     factories +       progress
                         auto-restart      notifications

    ui/status.lua  ◄── wires View + Tree + sections
          |
    ui/view.lua    ◄── window lifecycle, keybindings, refresh
    ui/tree.lua    ◄── foldable tree widget, rendering
    ui/actions.lua ◄── action factories (closures capturing context)
    ui/helpers.lua ◄── shared formatting (progress, elapsed, status)
          |
    ui/sections/   ◄── pure rendering functions, one per section
      diagnostics.lua
      tasks.lua
      profiles.lua
      orphaned.lua
      config_sets.lua
      projects.lua

    lua/overseer/component/loomworks/task_tracker.lua
        ◄── overseer component bridging task lifecycle to ConfigUnit

    lua/lualine/components/loomworks.lua
        ◄── winbar component showing active profile/project/config
```

---

## Design Principles

These principles guide all development decisions. When in doubt, choose the
simpler option.

1. **Simplicity over abstraction.** Prefer one class with differentiating
   properties over multiple classes. Example: there is one Profile class —
   set-based vs pinned profiles differ by `configuration_set` being non-nil
   or nil, not by type hierarchy. If two concepts have 80% overlap, make
   them one thing with a flag rather than two separate implementations.

2. **No duplicate functionality.** Before adding a new function, method, or
   concept, check if an existing one can be extended. Audit for overlap —
   if two methods do similar things, combine them or make one call the
   other. This applies at every level: API functions, internal helpers,
   data model concepts, UI sections.

3. **API over data model.** Consumers (integrations, UI, external plugins)
   use `require("loomworks")` public API. They never reach into raw
   workspace, cache, or config data directly. The public API is the
   contract; internal data shapes can change freely.

4. **Single source of truth.** Each piece of state lives in exactly one
   place. Runtime state (running, deleting, progress) → ConfigUnit.
   Persistent build state → cache.json. Working state and intent →
   user.json (the runtime source of truth, see specification.md §2.2).
   Published snapshot → loomworks.json (regenerated on `:w`, never read
   directly at runtime). If you find the same information stored in two
   places, eliminate one.

5. **Constructor injection for testability.** Core uses `Core.new(deps)`
   with a default dependency table that tests can selectively override.
   All external dependencies (I/O, vim APIs, time, scheduling) go through
   the deps table — never call `vim.fn`, `vim.uv`, or `os.date` directly
   from core.lua or workspace.lua. Workspace accesses deps via
   `self._core._deps`. This makes every behavior testable without mocking
   globals.

   ```lua
   local DEFAULT_DEPS = {
     workspace = require("loomworks.workspace"),
     merge     = require("loomworks.merge"),
     events    = require("loomworks.events"),
     user      = require("loomworks.user"),
     cache     = require("loomworks.cache"),
     config    = require("loomworks.config"),
     io        = require("loomworks.io"),
     modules   = require("loomworks.modules"),
     FileTracker = require("loomworks.file_tracker"),
     read_file_async  = require("loomworks.io").read_file_async,
     read_files_async = require("loomworks.io").read_files_async,
     detect_tools_async = require("loomworks.merge").detect_tools_async,
     notify    = vim.notify,
     now       = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
     clock     = function() return vim.uv.hrtime() / 1e9 end,
     normalize = vim.fs.normalize,
     schedule  = vim.schedule,
     get_overseer_task = function(task_id) ... end,
     buf_name  = function(bufnr) ... end,
   }
   ```

   Tests override only what they need:

   ```lua
   local core = Core.new({
     io = mock_io,
     modules = mock_modules,
     notify = function() end,
     schedule = function(fn) fn() end,
   })
   ```

6. **Objects over keys.** In runtime code, pass objects (Profile, Project,
   ConfigUnit) rather than string keys that require lookup. Objects carry
   their context — the recipient can query state directly without reaching
   back into core or the data model. Keys are opaque identifiers — they
   exist for disk format (cache.json), internal registries, display, and
   event data, but are never parsed at runtime to extract structure. Read
   structured data from object fields instead.

7. **Methods over free functions.** If a function takes an object as its
   first parameter and is clearly about that object, it should be a method
   on the object rather than a standalone function elsewhere. Example:
   `profile:status()` not `compute_profile_status(profile)`. This keeps
   related behavior co-located and discoverable.

8. **Pure where possible.** Functions that don't need state should not have
   state. merge.lua is pure (data in, data out). The static helpers in
   workspace.lua (`resolve_root`, `paths`, `assemble`) are pure. Modules
   are stateless — they receive paths and config, return results. Core is
   infrastructure-only (I/O, deps, setup). Workspace is the single owner
   of all mutable domain state.

---

## Layers and Dependency Rules

The codebase has six layers. Dependencies flow **downward only** — a layer
may import from its own layer or any layer below it, never above.

```
┌─────────────────────────────────────────────────────┐
│  Entry Points       plugin/loomworks.lua, init.lua  │
├─────────────────────────────────────────────────────┤
│  Integrations       overseer, lsp, fidget, lualine  │
├─────────────────────────────────────────────────────┤
│  UI                 status, view, tree, sections,   │
│                     actions, helpers                 │
├─────────────────────────────────────────────────────┤
│  Domain             workspace, profile, project,    │
│                     config_unit, configuration_set,  │
│                     operation, merge, cmake_kits     │
├─────────────────────────────────────────────────────┤
│  Infrastructure     core, events                     │
├─────────────────────────────────────────────────────┤
│  Data / IO          config, user, cache, io,         │
│                     file_tracker, modules/*,          │
│                     progress/*, types                 │
└─────────────────────────────────────────────────────┘
```

**Key dependency rules:**

1. **init.lua** is a thin facade — it creates one `Core` instance and
   delegates every public function. No logic lives here.
2. **core.lua** is infrastructure only — it owns the dependency table,
   async setup, file validation, nuke_cache, and project_for_buf. It
   creates a `Workspace` instance during setup and provides thin delegation
   wrappers so that init.lua callers continue to work via `core:method()`.
3. **workspace.lua** is the domain container — the `Workspace` class owns
   all object registries and mutable domain state. All business logic
   (remerge, sync, persistence, operations, deletion, task tracking, tool
   scanning, mutation methods) lives here. Domain objects reference
   Workspace (`_workspace`), not Core.
4. **merge.lua** is a pure function — takes workspace data in, returns
   ActiveSet out. No side effects, no I/O, no state.
5. **UI sections** receive a `(tree, ctx)` pair and call tree methods to
   render. They never call io.lua, cache.lua, or core.lua directly — all
   data comes through `ctx` (assembled in status.lua) or `require("loomworks")`
   for API calls. UI callers that mutate state (project_browser, actions)
   obtain the Workspace via `lw.get_workspace()` and call workspace methods
   directly (e.g., `ws:add_project()`, `ws:add_configuration_set()`).
6. **Modules** (cmake, meson, shell, typescript) know nothing about
   profiles, UI, or overseer. They implement the module interface (validate,
   info, tasks, inspect, detect_tools) and operate on project paths and config
   data.
7. **Integrations** (overseer, lsp, fidget, lualine) consume the public API
   via `require("loomworks")` and listen for events. They never import
   core.lua directly.
8. **config_unit.lua** is shared across layers — Workspace creates and owns
   units, but UI and integrations read their state. Units are the single
   source of truth for runtime state (see specification.md §1.7, §3.1).

---

## Component Responsibilities

### Entry Points

| File | Owns | Must NOT do |
|------|------|-------------|
| `plugin/loomworks.lua` | Command registration (`:LoomworksInit`, `:LoomworksInfo`), double-load guard | Contain logic; import core.lua |
| `init.lua` | Singleton Core instance, public API surface, version string | Hold state beyond the Core ref; contain business logic |

### Infrastructure Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `core.lua` | Dependency table (`_deps`), workspace lifecycle (`_state`, `_setup_error`), async setup (`setup`, `_on_files_read`), project validation (`_validate_projects`), nuke_cache, delete_user_prefs, `_safe_nvim_path`, `project_for_buf`, shutdown. `load()` tears down any prior workspace before replacing; `shutdown()` calls `Workspace:teardown` and drops the ref. Thin delegation wrappers forward to Workspace for init.lua callers | Hold domain registries; contain business logic; do I/O directly; know about UI |
| `events.lua` | Pub/sub system: `on()`, `off()`, `emit()` | Hold domain state; know about specific event semantics |
| `reload.lua` | Dev-only `:LoomworksReload` orchestrator. Calls `core:shutdown()` to tear down the active workspace, then asks lazy.nvim to reload loomworks + installed sibling plugins (`loomworks-module-ohos.nvim`). Lazy clears `package.loaded` and re-runs each plugin's `config` callback, which re-calls `setup()` | Workspace business logic; bypass `core:shutdown` |

### Domain Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `workspace.lua` | **Workspace class**: all object registries (`_projects`, `_profiles`, `_config_sets`, `_profile_projects`, `_config_units`, `_operations`, `_tools_by_type`, `_active_set`), tool state (`_tool_state`, `_tool_waiters`), delete waiters, build dir reverse index (`_build_dir_refs`: normalized dir → set of cache keys, rebuilt in `_sync_build_dir_refs()` during remerge), build dir operation locks (`_build_dir_locks`: per-dir exclusive/shared locks with FIFO queue, `acquire_build_dir_lock`/`release_build_dir_lock`). Shared baseline (`_shared_baseline`: raw parsed loomworks.json, updated on load and `:w`). Business logic: remerge (per-configuration merge of user.json + loomworks.json), `_sync_*`, `_save_cache`, `_save_config` (publish to loomworks.json), `_save_user` (working copy), `_serialize_config`, `publish()` (`:w` handler — full regen), `publish_one(item)` (per-item partial loomworks.json write — preserves untouched entries), `revert_to_baseline()` (`:e!` handler — data-preserving force revert; locally-added items demote to `local`), `revert_one(item)` (per-item baseline restore / removed-upstream demote), `_publishable_to_shared` (transitive effective-intent closure, used by serialization), `_mark_removed_upstream(old_baseline)` (session flag set after baseline change, cleared on publish/revert), `create_operation`, `execute_deletion`, `reset_all` (headless hard-reset of every build dir + orphaned dirs, spec §16.30), `_pre_configure_reset(build_dir, entries)` (full-reconfigure support, spec §5.1/§8.1: validates the build dir under the workspace root via `_validate_build_dir`, accepts only plain relative entries whose canonical path lies strictly inside it, then unlinks/rm-rfs them; synchronous, no cache mutation), `record_task_result` (a *configure*'s `module_info` **replaces** the unit's record — so a key the module stopped returning, e.g. meson's `cross_file` after `machine_file` is dropped, reads as absent rather than surviving and forcing a full reconfigure forever; any other task's `module_info` is merged, so a build never wipes the configure record; on a configure it also freezes `cache_launcher` — the configure result's value or nil — for `is_stale`; and, after a successful configure that applied a launcher, runs the module's `cache_compat_scan` via `compiler_cache.run_compat_scan`, notifies any findings, and stores the result as `module_info.cache_compat` — replaced every configure, nil when failed / no launcher; the scan ctx carries `configuration_env`. On every configure it also freezes core's record of the resolved configuration environment in `module_info.configure_env` — nil when empty — for the env staleness axis and the module's full-reconfigure decision), `_scan_tools_async`, `_refresh_lsp_database_for(unit)` (generic — drives a module's owned LSP compilation database via the `refresh_lsp_database`/`lsp_database_watch_path` hooks; called after configure/build completion in `record_task_result` and during the startup `_scan_targets_async`; registers the reply-dir `fs_poll` watch). Modified computation: `is_project_modified`, `is_config_modified`, `is_config_set_modified`, `is_profile_modified`, `has_any_modified`. Mutation methods: `add_project`, `remove_project`, `add_configuration_set`, `remove_configuration_set`, `update_config_set_mapping`, `rename_project_configuration` (atomic rename with cache migration), `create_profile`, `activate_profile`, `upgrade_profiles_for_tool`, `downgrade_profiles_from_tool`. Preview: `compute_downgrade_preview`. Query methods: `query_available_configs`, `map_variant`, `generate_default_config_sets`, `get_module`. File tracking: `_start_tracking`, `_stop_tracking`, `_on_file_changed` (snapshots old baseline before remerge, calls `_mark_removed_upstream`, always saves user.json so sticky intent survives restart), `reload_config`. Lifecycle: `on(event, handler)` records workspace-scoped event subscriptions in `_event_handlers`; `teardown()` stops the file tracker, cancels in-flight overseer tasks (collected from `_config_units._task_id`), detaches recorded subscribers, drops `_build_dir_locks`, and clears runtime caches — called by Core on workspace swap and shutdown. **Static helpers** (on the module table, not the class): `resolve_root`, `paths`, `assemble` (pure), `create_workspace_config` (bootstrap) | Do I/O directly (delegates via `_core._deps`); know about UI; render anything |
| `merge.lua` | Three-file merge algorithm, profile collection, orphaned project detection, tool detection (sync and async) | Mutate state; do I/O; depend on core.lua or workspace.lua |
| `configuration_set.lua` | ConfigurationSet class: identity-preserving with `_update()`, owns activation (`activate()`/`ensure_profile()`), property-based profile lookup (`find_profile()`), resolves Project references internally. `update_mapping()` cascades `_mark_user_owned` to the set, the project, and the new config (specification.md §2.4 implicit cascade-on-use). References Workspace via `_workspace` | Own state beyond config data; do I/O |
| `profile.lua` | Profile and ProfileProject classes. Profile owns `_tool_keys` (flat string array, user-ordered, first-match-per-language resolution wins), `tools_for(configuration)` for language-keyed effective tools, `tool_for(mod_type)` compat shim, `add_tool(key)` / `remove_tool(key)` mutators, `toolchain_entries()` UI surface, `missing_languages_for(configuration)` / `language_gaps()` / `unused_tools()` validity probes, status aggregation, plan_deletion, activate/deactivate. `Profile:activate()` cascades `_mark_user_owned` through the profile, its config set, and the set's mappings — so user.json is self-contained for the active profile. Profile also holds per-machine **fill values for blank project variables** (`_profile_variables`, project_key → name → value): `variable_value` / `set_variable_value` / `clear_variable_value` / `variables_data` accessors, `blank_variables()` enumerates the profile's still-blank declared variables, and `assert_buildable()` refuses configure/build while any is unfilled (core §1.3.1). Fill values live in user.json only (top-level `profile_variables`, mirrored on the Workspace as `_profile_variables_data` so they survive remerge) and are NEVER serialized to loomworks.json. Profile resolves mappings + ConfigurationSet reference in `_apply()`. Profile.key derives from `<set>:<sorted-deduped-tool-keys>` — no separate SDK component (kit_id prefix carries it). ProfileProject registered in Workspace, holds direct refs to Profile + Project. References Workspace via `_workspace` | Own state beyond what workspace provides; do I/O |
| `project.lua` | Project class, config_cache_key computation, mutation methods (save_options, save_type_config_field, save_variable, save_launch_config, etc.). References Workspace via `_workspace` | Own state beyond what workspace provides |
| `config_unit.lua` | Per-(project, config) runtime state: running action, progress, elapsed time, deleting flag (with reason: "deleting"/"cleaning"), queued action. Synced during remerge (`_update()` refreshes variant/tool from cache, preserves runtime state) + lazy creation via `get_config_unit()`. Listener pattern via `on_state_change()`. Owns `materialize()`, `materialize_pinned()`, `resolve_tool()`, `referencing_profiles()`, `active_compiler_family()`, `context_profile(profile?)` (the profile whose fills a resolution uses — the caller's, else the active one; spec §5.1 *Resolution context*: every staleness method below takes an optional `profile`, and the build gate (`overseer` `lw_meta.profile` / plan-step `profile`), `record_task_result` (`result.profile`), `Profile:compiler_cache_status` and the status page pass the profile being built / shown, so a non-active profile's `cache` or variable fill is never judged against the active profile's), `resolved_option_fingerprint(profile?)` (options merged across inheritance + expanded through built-ins and family-aware project variables, including the context profile's blank-fill values — the RESOLVED `-D` values `is_stale()` compares against the snapshot taken at configure time; changing a profile fill value therefore makes the unit stale and forces a reconfigure). `build_dir_present()` / `missing_build_dir_needs_reconfigure()` — the build-gate re-check for a build directory removed out of band (spec §3.1 rule 7); the plain directory stat comes from the injected `dir_exists` dep, and `unknown`/`deleting` are exempt. `is_stale()` also folds in a **compiler-cache launcher axis** via `launcher_changed(profile?, lookup?)` (injectable detection for deterministic tests): it recomputes the launcher `compiler_cache.resolve_for` would produce now (policy + family + live PATH presence) (or `"none"` when the module's optional `cache_launcher_applicable({configuration, tool_data})` hook returns false — e.g. a cmake preset, which cannot take the launcher) and compares to the value frozen at configure in `module_info.cache_launcher` — an appeared/disappeared/changed launcher marks the unit stale so the build gate reconfigures. A `nil` recorded value is not compared (the module records no launcher); a configure with no cache records the sentinel `"none"`, so a later-installed cache still differs and fires. **Configure-record migration** (spec §5.1): `record_outdated()` — a configured unit (`_was_configured()`: snapshot, or a configured/built/failed_build state) whose `module_info.record_version` differs from its module's `configure_record_version` (stamped by `Workspace:record_task_result` after a SUCCESSFUL configure only) was recorded by an older lw → stale, and the module takes the full reconfigure; modules without the field skip the check. `stale_reason()` returns the first applicable reason (`configure record from an older lw`, `options changed (FOO removed)`, `module configuration changed`, `configuration environment changed`, `compiler launcher changed`) and `is_stale()` is `stale_reason() ~= nil`; `configure_reason(forced?, profile?)` is the build gate's full reason (first configure / forced / previous configure failed / stale reason / project files changed / build directory missing). **Configuration environment** (spec §1.3.3): `configuration_env()` resolves the configuration's `env` through `config_env.resolve` (chain + family overrides, expanded with the same context as the option fingerprint, reserved names stripped); `env_changed()` compares it with core's record `module_info.configure_env` (absent ⇒ empty — no env was applied before the field existed) and is folded into `is_stale()`, so an env change makes the unit stale and the module takes a full reconfigure. References Workspace via `_workspace` | Persist anything (runtime only) |
| `device.lua` | Device domain object: physical/emulated deployment target with serial, display_name, provider (module id), state (online/offline), properties. Runtime-only (not persisted). Workspace-level registry, discovered via module's `list_devices()` | Persist anything (runtime only) |
| `launch_target.lua` | LaunchTarget class: resolves profile's default target descriptor into object references (Project, ConfigUnit, Target). Three target types: module targets, command launches, device targets. `build()` builds deps → pre-build deploy → build self. `deploy()` executes post-build deploy steps. Both phases merge project-level + launch-level deploy. `launch()`/`debug()` for local targets. `device_install()`/`device_launch()` for device targets. `requires_device()` returns true for device targets | Own state beyond resolution; do I/O directly |
| `debug.lua` | DAP integration gateway. `run(spec, callbacks)` constructs DAP launch config with adapter-specific `extra` fields and calls `dap.run()`. Checks adapter availability before launch (Mason install hint). `resolve_adapter(workspace, module_type)` reads `user.json` debug settings with defaults (cmake→codelldb, typescript→pwa-node). `known_adapters(module_type)` returns picker options. Per-session callbacks via unique listener keys | Own state; depend on workspace internals |
| `session_tracker.lua` | Unified launch/debug lifecycle manager. Tracks active run (overseer task or dap session). `start(target, mode)` handles confirmation dialog, build→deploy→execute chain with device extension (device-install→device-launch for device targets), fidget progress. `stop()` terminates overseer task or dap session (with `hierarchy=true` to kill debuggee). Auto-cleans tracked run on dap session end via listeners | Own state beyond what init.lua provides |
| `target.lua` | Target class: wraps module-detected build target (type, dependencies, artifact). `build()` delegates to module. `launch()` runs executable via overseer. Runtime-only, recreated on parse | Persist anything |
| `deploy.lua` | Deploy step validation, resolution, freshness checking, execution, cleanup. Pure functions — no state. Resolves source config units within profile context, compares mtime + source identity for freshness, copies files. `partition_by_phase()` splits a deploy dict by `pre_build` flag. `merge_deploy_sources()` merges project-level and launch-level deploy (directory destinations union, file destinations override) | Own state; do I/O beyond file copy |
| `variables.lua` | Project variable validation and resolution. `resolve(project, configuration, active_family, profile)` walks the inheritance chain via object references, returns values with provenance (source Configuration object + `from_override` / `from_profile` flags); at each level a matching compiler-family `overrides[active_family]` entry wins over the plain `variables` value, chain position dominating compiler-specificity (core §1.3.1). `default` is OPTIONAL: a declaration with no default/override/profile value resolves *blank* (value `nil`). The **profile-fill layer** is the final fallback — when still blank after the config chain, `profile:variable_value(project.key, name)` supplies the machine-local value (blanks only; never shadows a set value). `blank_variables(project, configuration, active_family, profile)` reports the still-blank names (build-gate + diagnostic input). Reserved name checking; `validate_compiler_overrides` (undeclared-name reject) + `unknown_families` (diagnostic input). Compiler family comes from the active tool via `cpp_compilers.family_from_tool_data` (clang-cl → clang). **Pre-declared policy variables** live in `PREDECLARED_NAMES` (v1: `cache`) — NOT expansion built-ins (those stay in `RESERVED_NAMES`): a pre-declared name is rejected as a *declaration* yet allowed as an *override* target (plain / compiler-family / profile-fill, incl. boolean `false`). `resolve_cache_policy(project, configuration, family, profile)` reads the effective `cache` policy through the same override machinery (config chain → family override → profile fill → built-in `auto` terminal). `env` is a reserved namespace name (`NAMESPACE_NAMES`): it cannot be declared, and inside a compiler-family `overrides` block it is the environment sub-block (`overrides.<family>.env`, validated as a name → string map, exempt from the declared-name rule) | Own state; mutate anything |
| `config_env.lua` | **Configuration environment resolution** (spec §1.3.3). `merged(configuration, family)` merges `env` across the inheritance chain (bases depth-first, then own; per level plain `env` then the matching `overrides[family].env`, so a nearer plain value shadows a farther family entry); `expansion_context(project, configuration, family, profile, root)` builds the built-ins + resolved-variable context shared with `ConfigUnit:resolved_option_fingerprint`; `resolve(...)` returns the expanded env with reserved compiler-driver names stripped (plus the stripped list, warned once); `compose(tool_env, config_env)` layers it over the tool env. The single resolver for the task context (overseer), the configure snapshot and staleness (ConfigUnit), and test runs | Know about any module; do I/O |
| `reserved_compiler.lua` | Single definition of the compiler keys owned by the tool: the `^CMAKE_.+_COMPILER$` cache-var pattern and the compiler-driver env set (`CC`, `CXX`, `FC`, `CUDACXX`, …). `is_reserved_option` / `is_reserved_env` are consumed by `Project:save_configuration` (reject at edit), the cmake/meson task builders (strip at build), and `Configuration:compiler_override_warnings` (inline diagnostic). See spec §15 "The tool owns the compiler" | Know about any module; detect anything |
| `nice.lua` | Linux nice/ionice cmd wrapper. `wrap_cmd(cmd)` prepends `ionice -c 3 nice -n 10` on Linux when both binaries exist, returns cmd unchanged otherwise. Probe is cached (`_reset_cache()` for tests). Used by `overseer.lua` for build/configure/clean tasks and `loomtest/runner.lua` for test runs | Know about specific commands or modules |
| `operation.lua` | Operation class: tracks a user-initiated profile action. Watches ConfigUnit state changes to determine completion. Multiple Operations can coexist. Created by `Workspace:create_operation()`, cleaned up on completion via callback | Own state beyond what workspace provides; persist anything |
| `workspace_view.lua` | View-model layer: orchestration logic for UI. Computes add/remove project context, tool detection caching, upgrade/downgrade previews, config set candidates. Config set create/edit/rename/delete context and execution. Orphan cleanup: stray build dir detection (top-down prune of `.nvim/build/`), orphaned config collection, bulk cleanup execution. Calls Workspace atomic mutations in sequence. No UI rendering — pure compute + execute | Render UI; own state; bypass Workspace methods |
| `cmake_kits.lua` | CMake tool detection: maps toolchains to CMake kits. GCC/Clang detection delegates to `cpp_compilers.lua`; MSVC + clang-cl discovery delegates to `msvc.lua`. Emits VS-generator MSVC kits, Ninja+MSVC kits, and one Ninja+clang-cl kit per MSVC install (paired vcvars + sibling clangd). Both sync (`detect()`) and async (`detect_async()`) variants. In-memory caching of results | Do I/O beyond process spawning for detection; re-implement MSVC/vswhere discovery (delegate to `msvc.lua`) |
| `msvc.lua` | Shared MSVC/Visual Studio discovery for all modules (cmake + meson). `detect()` / `detect_async()` enumerate VS installs via vswhere and locate each `vcvarsall.bat`; `vcvars_env(vcvarsall, arch)` snapshots the INCLUDE/LIB/PATH environment vcvarsall establishes; `clang_cl_for(install)` resolves that install's clang-cl (VS-bundled preferred, standalone/PATH fallback) plus a sibling clangd; `normalize_exe` fixes exe-extension casing. Process-lifetime caches; `clear_cache()` forces rescan | Know about any specific module; build kits/tools (that is the consumer's job) |
| `cpp_compilers.lua` | Single source of truth for C/C++ compiler identification. `detect()` / `detect_async()` probe PATH for gcc/clang/versioned variants; `probe_path(path)` identifies an arbitrary user-supplied executable. Returns `{id, display, family, version, path, c_path, bin_dir, clangd_path}` per compiler so modules can pin `CC`/`CXX` and prepend runtime-DLL directories to `PATH`. Used by `cmake_kits.lua`, `modules/meson.lua`, and `sdks/cpp_compiler.lua`. All compiler-family knowledge (regex patterns, sibling-driver naming, clangd discovery gated on Clang) lives here. `is_msvc_style(tool_data)` is the single **MSVC-ABI** signal (cl OR clang-cl) — used by the compiler-cache `auto` rule (no launcher under `auto` for MSVC-style, clang-cl included), cmake's `/Z7` + CMP0141 injection and the post-configure `/Zi` scan, since `family_from_tool_data` folds clang-cl → `clang` (right for overrides, wrong for those MSVC-ABI decisions). `pdb_debug_flag(args)` / `pdb_scan_add` / `pdb_scan_findings(acc, tool)` are the shared compiler knowledge behind both modules' `cache_compat_scan` (PDB-writing `/Zi`,`/ZI`,`-Zi`,`-ZI`; `"error"` for sccache, `"warning"` otherwise), and `pdb_env_findings(env, tool)` reports such a flag in the configuration environment's MSVC `CL` / `_CL_` (case-insensitive; `group = "environment"`, one finding per variable) — flags no compile-command listing shows. Process-lifetime cache; `clear_cache()` forces rescan | Know about any specific module |
| `compiler_cache.lua` | **Core-owned compiler-cache launcher resolution** (ccache/sccache). `resolve(policy, family)` maps a `cache` **policy** (`auto`/`off`/`<tool>`) + compiler family to a `{tool, path}` launcher (or nil) — `auto` resolves to **no launcher** for MSVC-ABI (msvc **and clang-cl**, via `cpp_compilers.is_msvc_style`; spec §1.3.2 — sccache fails `/Zi` compiles, so caching there is explicit opt-in) and prefers ccache for gcc·clang with sccache as fallback; explicit tools honored on any family; all gated on presence via the shared `cpp_compilers` PATH index (`lookup` injectable for tests). `resolve_for(project, configuration, tool_data, profile, lookup?)` resolves the effective policy through `variables.resolve_cache_policy` first (override family folds clang-cl → clang; the launcher-preference family keeps clang-cl MSVC-ABI) and returns `(launcher, normalized_policy)`; it is the single resolver for both the build context and `Profile:compiler_cache_status()` (status/health), so what is reported is what a build applies (the status also asks the module's `cache_launcher_applicable` hook via `applicability(impl, configuration, tool_data)` — `(applicable, reason?, hint?)`, pcall-guarded, shared with `ConfigUnit` launcher staleness — and reports `not applied (<reason>)`, never a launcher the module will not inject). `run_compat_scan(impl, ctx, launcher_path)` invokes a module's optional `cache_compat_scan` hook (pcall; a throw is recorded as skipped) and returns the `{tool, scanned, reason?, findings[]}` record; `compat_severity`/`compat_group_lines`/`compat_message` format it for the end-of-configure message and health. `auto_off_for_family(policy, family)` tells status/health that `auto` deliberately left an MSVC-style build uncached (vs none found). `any_present()` for status/health. No module-specific logic — modules apply the launcher they receive via the `compiler_cache` ModuleContext field. `normalize_policy` folds `false`/off-synonyms | Know about any specific module; apply the launcher (that is the module's job); spawn the cache tool |
| `suggestions.lua` | **Extensible advisory suggestion framework** (headless §16.31). Two provider lists: **passive** (`register(fn)`) — side-effect-free, no network, run by `collect(workspace)` which feeds both the compact `N suggestions` line (status page + `lw status`) and health; and **on-demand** (`register_health(fn)`) — may hit the network, run ONLY by `collect_health(workspace)` (the `lw health` full report), never by the passive count. Neither `collect` nor `collect_health` guards a nil `workspace` at the top — each provider guards nil itself, so workspace-INDEPENDENT providers still run without one. Both flatten results and skip a throwing provider. Items carry a `kind` (`"suggestion"` default = actionable, `"info"` = informational); `count_actionable(workspace)` (what the `N suggestions` line uses) counts only actionable ones, so an affirmative info item never inflates the nag total. Provider #1 `compiler_cache_provider` (passive, **workspace-scoped** — returns `{}` on nil workspace): for a workspace with a non-orphaned C/C++ project (`Module:caches_cpp()`) not pinned `cache` off, returns ONE terse item (title + short remedy, no prose — the explanations live in the `lw help cache` topic, aliases `sccache`/`ccache`). With an ACTIVE profile it follows that profile's `compiler_cache_status()` (`status_outcome`, so health never contradicts the `Cache` row): policy `off` → silent; not applicable → `info` "Compiler cache not applied (`<reason>`) — lw help cache"; launcher resolved → `info` "Compiler cache: using `<tool>`"; explicit `cache=<tool>` not found → actionable "cache=`<tool>` set but `<tool>` not found"; MSVC-style under `auto` with a cache on PATH → `info` "`<tool>` available — not enabled for MSVC-style (lw help cache)"; else actionable "No compiler cache found" (`install_remedy`: `_preferred_install_tool()` — sccache on Windows, ccache elsewhere — plus "then opt in" for MSVC-style). With NO active profile it evaluates every profile's status (`all_cache_statuses`) and never claims "using" unless some profile would use the launcher: all `off` → silent; some resolve a launcher → `info` "Compiler cache: using `<tool>` (`<profiles>`)"; an explicit tool not found → actionable (names the profile); a cache on PATH → `info` "`<tool>` available — not enabled[ for MSVC-style] (lw help cache)" (no profiles: "`<tool>` available"); else the install nag. The local-tier key folds in every profile's tool keys, mapping and `cache` fills plus the active key. Provider `cache_compat_provider` (passive, workspace-scoped): reads the recorded `module_info.cache_compat` of the active profile's units — with no active profile, every profile's units (profiles by key), deduplicated per unit (`_compat_records`) — an actionable item per configuration with findings (detail = the group lines, remedy = one line: /Z7 or `cache off` — `lw help cache`), an `info` item for a skipped scan (detail = why); the local-tier key (`_local_key`) folds those records in. Provider #2 `update_check_provider` (on-demand, **workspace-independent**): reads the running release version from `_G.__loomworks_luaroot`, resolves the newest version on the channel via `boot.update.resolve_newest_version` and compares with `boot.paths.version_gt` → "Update available"; silent for a dev/fused/editor source, unknown channel, offline/API failure, or already-current. `channel_override_provider` (on-demand, network-free, **workspace-independent**): flags a release-url override superseding a non-default channel via `boot.update.url_override`/`resolve_channel`. Reads only resolved state / the PATH index — never spawns a build tool. **Results are cached** (see `health_cache.lua`): `collect`/`collect_health` read/write `.nvim/loomworks.health.json` so the passive count stays cheap and never hits the network. `_local_key(ws)` is the cheap local-tier invalidation fingerprint; `_clock` (`os.time`, injectable) and `NETWORK_TTL` (~24h) govern the network tier's throttle; `collect_health(ws, {force=true})` forces a network refresh | Gate any operation (advisory only); spawn the cache tool; run a network provider on a passive render; own persistent state (that is `health_cache.lua`) |
| `health_cache.lua` | **Advisory suggestion cache** (headless §16.31) for `suggestions.lua`. Pure module over an injected io: `read(io, root)`/`write(io, root, data)`/`path(root)`/`empty()`, own `SCHEMA_VERSION` independent of the build cache. Stores the two tiers (`local_tier {items,computed_at,key}`, `network_tier {items,computed_at}`) in `.nvim/loomworks.health.json`. Missing/corrupt/older-schema → `empty()` (never raises); atomic write via the io's `write_json`; `read_file`+decode fallback when the io lacks `read_json` | Compute suggestions or fingerprints (that is `suggestions.lua`); know about the build cache or deletion safety |
| `sdks/init.lua` | SDK provider registry, lazy loading via rtp discovery. Same strict-equality `api_version` check + one-shot-notify rejection as `modules/init.lua` | Implement provider logic |
| `sdks/cpp_compiler.lua` | User-declared C/C++ compiler SDK provider. No auto-detection (`detect_all` returns empty); user adds via the SDK section's `▸ Add SDK` action. Calls `cpp_compilers.probe_path` for identification; emits single-compiler cmake caps consumed by `cmake.kits_from_sdk`'s single-compiler branch. Provider-specific key derivation includes a path-derived token so two custom builds of the same family / version at different paths don't collide. See `spec/sdks/cpp_compiler.md` | Contain compiler family knowledge (lives in `cpp_compilers.lua`) |
| `device_log.lua` | Client-side device-log view: line parser (`MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: msg`), session prefilter (pid OR proc-contains-bundle, applied at receive), soft filter (level / regex / tag / pid, applied at render), ring buffer (5000 records), bottom-split scratch buffer with level-based extmark highlights. Singleton view, one stream at a time. Streaming task runs under `loomworks.overseer.run_streaming_task` (visible in overseer's task list, killable there) | Spawn subprocesses directly (overseer owns the process); persist filter state (in-memory only for v1) |

### Data / IO Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `io.lua` | Atomic file read/write (sync and async), JSON encode/decode, rm_rf (sync fallback), rm_rf_async (subprocess), directory creation, read_file_async/read_files_async (libuv callbacks) | Validate domain semantics; know about loomworks data model |
| `config.lua` | `loomworks.json` parsing, validation, project type extraction | Write files (config is read-only) |
| `user.lua` | `loomworks.user.json` parse/save/defaults | Validate beyond structural correctness |
| `cache.lua` | `loomworks.cache.json` parse/save/defaults, version checking | Business logic; auto-migration |
| `file_tracker.lua` | Watching three JSON files via `uv.fs_poll`, content-change deduplication; `watch_signal(path, cb)` adds a stat-change watch (no content read) for directories — used for the cmake file-api reply dir (owned-DB regen trigger) | Domain logic; know about merge or profiles |
| `config_editor.lua` | **Legacy** — retained for backward compatibility but not used at runtime. Mutation methods (`add_project`, `remove_project`, `add_configuration_set`, etc.) have moved to Workspace. Only `create_workspace` remains as a standalone entry point (paralleled by `workspace.create_workspace_config`) | Domain logic; know about runtime model |
| `api_versions.lua` | Strict-equality version constants (`module`, `sdk`) for the plugin-interface registries. Both `modules.get` and `sdks.get` refuse to load plugins whose declared `api_version` doesn't match. See specification.md §8.0 for the bump policy | Track an interface that already has a more direct registration path (LSP, debug) |
| `modules/init.lua` | Module registry, lazy loading via rtp discovery, detection orchestration (`detect_all_types`, `scan_directory_async`). Strict-equality `api_version` check at load with one-shot notify on mismatch; rejected ids stay rejected for the session | Implement module logic |
| `modules/cmake.lua` | CMake module: detect, validate, info (preset + loomworks config separation), default_configurations, resolve_configurations (inheritance model), resolve_options/resolve_options_with_sources (option merge with source tracking), resolve_variant_source, tasks (CMAKE_BUILD_TYPE auto-set, user -D options), inspect, detect_tools/detect_tools_async, parse_targets (target discovery), get_options (cache variables), lsp_configs (clangd + qmlls entries). **Owns the clangd compilation database for EVERY generator** (Ninja/Make included, not just VS/Xcode): reconstructs `compile_commands.json` from the file-api into `.nvim/cache/cc/` and points clangd there, unless a config sets `compile_commands_generated = false` (fall back to the native DB) or `compile_commands_from` redirects. Never decodes the monolithic native DB — decodes only the chunked per-target file-api replies and **stream-encodes** its output entry-by-entry (`write_cc_stream`, never one giant `vim.json.encode`). Augments the DB with **header entries** via Tier-1 nearest-ancestor directory attribution (`_target_attribution_index` + `_build_header_entries`; listed headers direct, unlisted via a bounded dir listing, unattributable omitted). Regen is mtime-gated (`refresh_generated_cc`) and driven from three idempotent triggers via the generic hooks `refresh_lsp_database`/`lsp_database_watch_path`: lsp_configs, configure/build completion, and a reply-dir `fs_poll` watch. Also parse_targets (target discovery), map_variant. **Applies the core-resolved `ctx.compiler_cache`** on the non-preset configure path: injects `CMAKE_C/CXX_COMPILER_LAUNCHER` (feature-owns it over a user-set value, §4f) plus MSVC/clang-cl single-config `/Z7` (`CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded` + `CMAKE_POLICY_DEFAULT_CMP0141=NEW`, cmake ≥3.25, unless the user pinned either key or a `/Zi`-style option), warns on a preset, and records the launcher in `module_info.cache_launcher`. **Faithful reconfigure** (§5d, core §5.1): records every `-D` it passes in `module_info.passed_options` (on the preset path too — the appended user options); on the next configure ANY difference against that record, the recorded generator, or core's recorded `configure_env` vs the current `configuration_env` — or a configured unit with no record, or one whose `record_version` differs from `M.configure_record_version` (an older lw), or `force_full_reconfigure` — is a **full reconfigure**: `--fresh` (cmake ≥3.24, also with `--preset`) or `pre_configure_reset = {CMakeCache.txt, CMakeFiles}` below 3.24. The only in-place change is one confined to `CMAKE_C/CXX_COMPILER_LAUNCHER` (`IN_PLACE_KEYS`): re-passed, or retracted with `-U<key>`. **Launcher applicability**: `cache_launcher_applicable` returns `false, reason, hint` for a preset (`"preset"`) and for a generator outside the Ninja/Makefile families (`"<generator> generator"`, e.g. Visual Studio, Xcode — CMake ignores the launcher there); `M.tasks` then injects no launcher (nor the MSVC debug-info keys), records `"none"` and warns once. `cache_compat_scan` also reports a `/Zi`-style token in the configuration environment's `CL` / `_CL_` (`group = "environment"`). `cache_compat_scan(ctx)` scans every target's file-api `compileCommandFragments` (same reader as the owned compile_commands) for `/Zi`-style flags on an MSVC-style kit; `scanned=false` without a codemodel reply. Static `has_keyed_tools = true`, `has_options = true` | Know about profiles, UI, or overseer |
| `modules/meson.lua` | Meson module: detect (meson.build), validate, info (defaults Debug/Release/RelWithDebInfo mapping to buildtype), resolve_configurations (inheritance on top of defaults), tasks (meson setup + compile; auto-picks --reconfigure on re-setup, or the full `--wipe` reconfigure below (a launcher change included — meson fixes the compiler command at first setup); pins the compiler+launcher via a **generated `--native-file`** `[binaries]` LIST — space-safe, unlike the `CC`/`CXX` env string meson shlex-splits — or the bare compiler when off, suppressing meson's implicit PATH ccache, and records the launcher (or the `"none"` sentinel) in `module_info.cache_launcher`; records its `-D` options in `module_info.passed_options` (plus `buildtype` and `cross_file`) and, on ANY changed configure input vs those records, the recorded launcher, or core's recorded `configure_env` — or a configured unit with no record, or one whose `record_version` differs from `M.configure_record_version` (an older lw), or `force_full_reconfigure` — does the full reconfigure: `pre_configure_reset = {meson-private/cmd_line.txt}` + `setup --wipe` (no in-place set; an unchanged re-setup uses `--reconfigure`); `cache_compat_scan(ctx)` reads `meson-info/intro-targets.json` directly (no spawn) for `/Zi`-style per-source parameters on an MSVC-style tool; -D option args; optional --cross-file), clean_tasks (meson compile --clean), parse_targets/parse_targets_async (via `meson introspect --targets`), get_options (via `meson introspect --buildoptions`, grouped by section), lsp_configs (clangd entry with build_dir as compile_commands_dir), inspect (meson.build / meson.options / meson_options.txt staleness), detect_tools/detect_tools_async (meson on PATH, then pip-user Scripts dir via Python sysconfig probe; non-keyed), create_test_unit (MesonTestUnit), map_variant. Static `has_keyed_tools = false`, `has_options = true` | Anything beyond the module interface |
| `test_units/meson.lua` | MesonTestUnit: wraps `meson introspect --tests` for discovery, gtest framework probing via shared helper, direct-exe gtest XML runs for per-test results. Same runtime surface as CTestUnit | Know about the meson module internals |
| `modules/shell.lua` | Generic shell-command runner. Wraps user-declared `configure_cmd`/`build_cmd`/`clean_cmd` with variable expansion. `progress_parser` returns the ninja parser unconditionally (try-only: matches `[N/M]` lines, no-ops otherwise so non-ninja shell builds simply emit no progress). `lsp_configs` emits a clangd entry only when `shell.compile_commands` is set. `detect = nil` (manually-declared only). Static `has_keyed_tools = false`, `has_options = false`, `has_devices = false` | Auto-detect; introspect build options; own build-system knowledge |
| `modules/typescript.lua` | TypeScript shim module (detect + validate + info + default_configurations + detect_tools_async + map_variant). Defaults always present, user configs merged on top. Static `has_keyed_tools = false`, `has_options = false` | Anything beyond the shim interface |
| `progress/init.lua` | Parser registry mapping tool names to parser functions | Parse output itself |
| `progress/ninja.lua` | Ninja `[n/m]` output parser | Know about other build tools |
| `types.lua` | LuaCATS type annotations for all data shapes | Contain runtime code (never `require`d) |

### UI Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `ui/status.lua` | Wiring: creates Tree + View, assembles `ctx` from API, requires sections in order | Contain rendering logic; do I/O |
| `ui/view.lua` | Window lifecycle via Snacks.win (open/close/toggle), keymap registration, event-driven refresh, animation timer | Know about section content; contain domain logic |
| `ui/dialog.lua` | Snacks.win-based dialog helper for floating dialogs (help, confirm, options) | Domain logic |
| `ui/tree.lua` | Foldable tree widget: node/leaf/item/group/blank primitives, fold state, action dispatch (walk-up with action picker on Enter), buffer rendering | Know about loomworks domain; do I/O |
| `ui/actions.lua` | Action factories: capture context at render time, return closures for deferred execution. Deletion confirmation dialog. Profile creation multi-step picker (`create_profile`) | Render tree nodes; own state |
| `ui/project_browser.lua` | Directory browser float for adding/removing projects. Async scanning via modules, lazy fold-to-scan, add/remove via `ws:add_project()`/`ws:remove_project()`. Opens mapping_dialog when config sets exist | Own persistent state |
| `ui/mapping_dialog.lua` | Interactive Tree+View dialog for mapping a new project's configurations to existing config sets. Pre-fills via `ws:map_variant()`, accepts/cancels atomically | Own persistent state |
| `ui/config_set_editor.lua` | Edit dialog for config set mappings (create and edit). Editable name row with inline validation, project→variant picker rows. Used for both new and existing sets | Own persistent state |
| `ui/config_editor_dialog.lua` | Edit dialog for project configuration properties. Supports name, inherits (multi-base with reordering), options (unified view with inheritance sources), variables (override/clear with provenance), compiler-family `overrides` (read-only, marks the family active under the current profile's tool), toolchain, generator. Abstract mixin detection | Own persistent state |
| `ui/launch_editor.lua` | Edit dialog for launch config properties: name, command, args, working_dir, env, deploy steps. Deploy entries open deploy_editor on enter | Own persistent state |
| `ui/deploy_editor.lua` | Edit dialog for a single deploy step. Segment-based destination path builder (variable picker + literal text). Source picker for project, configuration, target (from domain objects). Resolved path preview | Own persistent state |
| `ui/variable_editor.lua` | Edit dialog for a project variable declaration: name, type (string/path), default value | Own persistent state |
| `ui/helpers.lua` | Shared formatting: progress strings, elapsed time, config status resolution | Side effects; domain logic |
| `ui/sections/*.lua` | Pure render functions `(tree, ctx) → void`. Each section is a single function that calls tree methods | Call core directly; do I/O; hold state |

### Integrations

| File | Owns | Must NOT do |
|------|------|-------------|
| `overseer.lua` | Template provider registration, task collection from modules, task launching with readiness checks and build dir lock acquisition, auto-configure-before-build (`filter_unconfigured_tasks` stamps each selected configure task's `configure_reason`; `configure_reason_line(meta)` composes it with the module's `reconfigure`/`reconfigure_detail` into the one-line report the CLI prints and `start_one_task` logs; `plan_profile_build(profile, { reconfigure = true })` forwards `force_full_reconfigure` into the module context and selects every configure task — `lw build --reconfigure`), profile-level operations; **nice/ionice cmd wrapping** for action ∈ {configure, build, clean} (Linux only, via `loomworks.nice`) so long tasks yield CPU/IO to the editor. **Assembles the `ModuleContext`** each module's `tasks()` sees, and single-sources the compiler-cache fields at every build-context site: `compiler_cache = {tool,path}|nil` (core-resolved via `compiler_cache.resolve_for`) that the module applies, and `recorded_cache_launcher` (the unit's frozen `module_info.cache_launcher`) that lets a module detect a launcher change, plus the previous-configure record `recorded_module_info` (the unit's `module_info`) / `recorded_options` (core's option snapshot) that lets a module classify a reconfigure, and the **configuration environment** (spec §1.3.3): `configuration_env` (resolved via `config_env.resolve`) and `env` = tool env with `configuration_env` layered on top (`config_env.compose`), at every context-assembly site (configure/build/clean, per-unit and per-profile, `build_spec_for`; `target.lua`'s per-target build uses the same composition) — all additive-optional (no `api_version` bump). **Faithful reconfigure** (spec §5.1): a configure task's optional `pre_configure_reset` (build-dir-relative configure-state entries) is executed by core — `start_one_task` runs `Workspace:_pre_configure_reset` after acquiring the exclusive lock and before the builder (refusal releases the locks and rejects), and `plan_profile_build` steps carry it (plus `module_info`) so the headless runner does the same | Import core.lua directly; own state beyond task generation |
| `lsp.lua` | LSP dispatch layer + plugin-style integration registry. On load, scans every runtime path for `integrations/lsp/*.lua` and requires each — integrations self-register via `register(server, M)`. Exposes generic `cmd(server, base)` / `root_dir(server, fallback)` factories, a `setup_servers(opts)` that installs enabled integrations via `vim.lsp.config` + `vim.lsp.enable`, buffer excludes (`default_excludes()` / `excluded(bufnr)` + `LspAttach` detach autocmd) applied uniformly across all managed integrations, `get_status()` dispatching per-server status fields to integrations, and the **generic restart machinery**: `wrap_on_exit(server, user_on_exit)` distinguishes managed-stop / clean external stop / unexpected death; `mark_managed_stop(client_id)` lets integrations flag their own intentional stops; per-`(server, root_dir)` throttle (4 attempts / 5min sliding window) deferring with `vim.defer_fn`; `is_suppressed` / `clear_suppression` / `reset_attempts` for the UI Reset path; subscribes to `lsp_options_changed` and dispatches to integrations' `on_lsp_options_changed` for cmd-affecting toggles. **`entry_for_project`/`entries_for` are content-memoized**: on `active_set_changed` every integration iterates every project through this resolver, so a per-project cache keyed on `{generation, ws.root, project.key, active-profile key, resolved build_dir/config_key/build-state/tool, fallback cached.build_dir + tool_data clangd, hash(type_config)}` returns the prior `module.lsp_configs()` result on a hit — a no-op switch and the second integration on a tick pay nothing. The memo is blown on `workspace_changed` and its keys invalidated (generation bump) on `lsp_options_changed`; the early return-on-hit is structured so a future mtime-guarded side effect inside `lsp_configs` is skipped on hits too | Contain server-specific wiring (lives in `integrations/lsp/<server>.lua`) |
| `integrations/lsp/clangd.lua` | clangd-specific wiring: `build_config(user_cfg)` for zero-config setup, function-based cmd + root_dir (resolve per-buffer: SDK clangd inside workspace, user base cmd outside), auto-restart on workspace/active set changes, capability auto-detection for blink.cmp/cmp_nvim_lsp, binary_required enforcement; **always-on `--pch-storage=disk`** + **user-configurable `--clang-tidy`/`--background-index`/`--background-index-priority`/`extra_args`** appended to every cmd (last-wins via LLVM `cl::opt`); reads via `Workspace:get_lsp_options("clangd")` (defaults applied); coalesced restart on `on_lsp_options_changed`; **OOM-adaptive `-j` step-down** via `on_unexpected_exit` (seed `-j 12` on first OOM, halve to 1 floor, give up after); single-retry policy for non-OOM crashes; nvim LSP log snapshot rotation (5 generations) on every (re)start; `reset(root_dir)` clears adaptive state and re-enables clangd | Reference specific modules; read `project.cmake` or other module-specific fields |
| `fidget.lua` | fidget.nvim progress handles for operations and tasks | Require fidget.nvim unconditionally (graceful no-op) |
| `task_tracker.lua` | Overseer component bridging task lifecycle to ConfigUnit, cache recording, and build dir lock release on completion/dispose (idempotent) | Be imported by anything except overseer |
| `lualine/components/loomworks.lua` | Winbar component showing active profile context for current buffer | Import core.lua; do anything beyond formatting |

---

## Data Flow

### Startup (async)

Startup is non-blocking. File reads and tool detection run asynchronously
so the Neovim UI is never frozen.

```
plugin/loomworks.lua
  → init.lua: setup({ root = path })
    → fidget.setup() (register event listeners — fast, no I/O)
    → core.lua: setup()
      → state = "initializing", emit "workspace_initializing"
      → read_files_async([config, user, cache])        ← libuv async I/O
        → vim.schedule → core._on_files_read()
          → workspace.assemble(root, config, user, cache)  ← pure, returns data
          → cache version check (refuse if incompatible)
          → core._validate_projects()
          → Workspace.new(core, data)                  ← creates domain container
          → ws:_migrate_set_names()
          → ws:_cleanup_orphaned_skeletons()
          → ws:remerge()                               ← merge + sync all registries
          → state = "initialized", emit "workspace_changed"
          → ws:_start_tracking(paths)                  ← file watcher owned by Workspace
          → ws:_scan_tools_async()
            → tool_state = "scanning", emit "tools_scanning"
            → detect_tools_async(config, cache)        ← vim.system for MSVC (msvc.lua) / compilers
              → vim.schedule → store results → ws:remerge()
              → tool_state = "scanned", emit "tools_detected"
              → flush _tool_waiters
              → ws:_scan_targets_async()                 ← active-profile units first
                → parse targets + refresh owned LSP DBs (§9.7)
                → active-profile DBs settled → _lsp_ready = true, emit "lsp_ready"
```

Every `*_async` detector is genuinely non-blocking. The "which binaries
exist" gate resolves each candidate name through a **cached PATH executable
index** (`cpp_compilers.lookup_path` / `_build_path_index`): the index is
built once by scanning each `$PATH` directory a single time with `fs_scandir`,
so a candidate lookup is O(1) instead of a full PATH search. Only **regular
files** are indexed — a `"file"` scandir entry directly, a link/unknown type only
when `fs_stat` (which follows links) says it is a file — so a directory named like
a tool (a `ccache/` folder on PATH) can neither be returned nor shadow the real
executable later on PATH. On Windows a name is an executable only when its
extension is in `PATHEXT` (the env var, default `.COM;.EXE;.BAT;.CMD`): the key is
the lower-cased base name without that extension, and within one directory the
earlier `PATHEXT` extension wins; the first PATH directory holding a name wins
overall. On Unix the filename is the key verbatim. (This replaced a
per-candidate `vim.fn.executable`/`exepath` gate that did ~76 full PATH
searches on every workspace load — ~850ms on Windows.) The slow part — each
`--version` / `vswhere` / `vcvarsall`-adjacent shell-out — runs off the main
loop via `vim.system(cmd, opts, cb)`. `cpp_compilers.detect_async`
fans out every compiler `--version` probe concurrently and aggregates them
with a completion counter before assembling; `msvc` exposes async
`clang_cl_async`/`clang_cl_for_async` siblings; `meson.detect_tools_async`
and `cmake_kits.detect_async` compose those async variants. Each async path
feeds the SAME assembly/order logic as its sync twin and populates the same
process-lifetime cache, so the async result is byte-for-byte identical to the
sync one (a sync `detect()` remains for the CLI and other callers).
`vcvars_env` stays synchronous: it is only reached from `compose_task_env` at
configure/build/test time (inside overseer tasks), never on the init path.

Workspace state: `uninitialized` → `initializing` → `initialized`
Tool state: `not_scanned` → `scanning` → `scanned`

The first remerge produces an ActiveSet with empty tools. Profile sections
render immediately. When tool detection completes, a second remerge fills in
detected tools and the UI refreshes via `active_set_changed`.

Materialization calls (`_materialize_from_data`, `materialize_configuration`,
`materialize_pinned`) that arrive during `scanning` are queued in
`_tool_waiters` and replayed when detection completes.

**Deferred LSP start.** loomworks installs its language servers (`vim.lsp.config` + `vim.lsp.enable`) during `setup()`, but their `root_dir` functions hold the start of any buffer under the workspace root until the active profile's owned compile_commands databases are generated (queued via the async `on_dir` callback), then release them so each server starts once with the resolved binary and a populated `compile_commands_dir`. The workspace root is recorded before servers are installed so the gate holds a buffer already open at startup. Buffers outside the workspace root, init failure, and a safety timeout release immediately with fallback resolution. See spec §9.7.

### File Change (hot-reload)

```
file_tracker (uv.fs_poll, 2s interval, owned by Workspace)
  → stat change detected → read content → compare to last known
  → ws:_on_file_changed(which_file, new_content)
    → config changed → reassemble + validate + update ws fields + remerge
    → user changed   → re-parse user data + remerge
    → cache changed  → re-parse cache data + remerge
  → ws:remerge() → events.emit("active_set_changed")
  → UI/integrations react to event
```

### Task Execution

```
User action (b/c key or API call)
  → overseer.lua: collect tasks from module
  → check ConfigUnit readiness (skip/defer/launch)
  → wait for pending deletions if any
  → acquire build dir lock (exclusive for configure/clean, shared for build)
    → if locked: queue task, start when lock available
  → launch overseer task with task_tracker component injected
    → task_tracker.on_start → ConfigUnit:set_running()
    → task_tracker.on_output → progress parser → ConfigUnit:set_progress()
    → task_tracker.on_complete → ws:record_task_result() → cache.save()
                               → ws:_refresh_lsp_database_for() (schedules async cmake owned-DB regen, mtime-gated; does not block the completion chain)
                               → ConfigUnit:clear_running()
                               → events.emit("task_result")
                               → release build dir lock → dequeue next
```

### Deletion

```
User presses D → actions.delete_profile/config/orphaned (closure)
  → show confirmation dialog (floating window)
  → on confirm:
    → mark ConfigUnits as deleting
    → stop running overseer tasks
    → wait for tasks to complete
    → set cache state to "unknown" + save (crash-safe)
    → vim.system() subprocess per build dir (parallel, async)
      → Unix: rm -rf <dir>
      → Windows: cmd /c rd /s /q <dir>
    → on subprocess completion:
      → success: remove/reset cache entries → cache.save()
      → failure: cache already "unknown", notify with stderr
    → check queued actions on ConfigUnits
    → unmark ConfigUnits → flush deletion waiters → remerge
    → events.emit("deletion_completed" or "deletion_failed")
```

---

## UI Architecture

The status page uses a **widget + section** pattern:

1. **View** (`ui/view.lua`) manages the window (open/close/toggle), registers
   keymaps, subscribes to events for auto-refresh, and runs the animation
   timer. It holds a reference to one widget.

2. **Tree** (`ui/tree.lua`) is the widget. It provides rendering primitives
   (`node`, `leaf`, `item`, `group`, `blank`) and handles fold state, action
   dispatch (walk-up to find `on_<action>`), and buffer writing. The tree
   accepts a render function that rebuilds its content on each refresh.

3. **Sections** (`ui/sections/*.lua`) are pure render functions. Each exports
   a single function `(tree, ctx) → void` that calls tree methods. Sections
   are required in order by `ui/status.lua`.

4. **Actions** (`ui/actions.lua`) are factories. They capture context
   (profile, project_key, config_key) at render time and return closures that
   execute at action time. This decouples rendering from execution.

5. **Helpers** (`ui/helpers.lua`) provide shared formatting functions used
   across sections (progress strings, elapsed time, status resolution).

**Adding a new section**: Create `ui/sections/foo.lua` exporting a function
`(tree, ctx) → void`. Require it in `ui/status.lua` at the desired position
in the render function. If the section needs new data, add it to `ctx` in
status.lua's `render_fn`.

**Adding a new action**: Add a factory function in `ui/actions.lua`. Attach
it to a tree node via `on_<action>` in the section's render function.

---

## Object Model

Workspace wraps raw merged data into domain objects that hold a `_workspace`
reference back to the Workspace instance for live queries and registry access.
Domain objects access infrastructure deps via `_workspace._core._deps`.
See [specification.md §1.6, §1.7](spec/core/data-model.md) for behavioral rules.

```
Core (singleton via init.lua)
  └── Workspace             ← domain container, owns all registries
        ├── Tool{}              ← per-module tool registry, from detection + cache
        ├── ConfigurationSet[]  ← from config, identity-preserving
        ├── Profile[]           ← from merge, identity-preserving
        │     └── LaunchTarget? ← per-profile default target (from user/config)
        ├── ProfileProject[]    ← registered, one per (profile, project) pair
        ├── Project[]           ← from active set, identity-preserving
        │     ├── Configuration[] ← from module.info() + user overrides
        │     └── variables{}     ← user-defined variable declarations
        ├── ConfigUnit{}        ← synced during remerge + lazy fallback
        │     └── Target{}      ← runtime, from module detection (set_targets)
        ├── BuildDir[]          ← cache artifacts, may be orphaned
        ├── _deploy_records{}   ← freshness tracking for deploy steps
        └── Operation[]         ← active profile actions, cleaned up on completion
```

All objects are **identity-preserving** across refreshes: the same table is
updated in-place via `_apply(data, ctx)`, never replaced. Construction uses
the same path (`new` calls `_apply`). Removed objects are marked
`_removed = true`.

**`_apply(data, ctx)`**: unified constructor/update method on each domain
object. Receives a plain data table and a deserialization context for
resolving keys to object references. Sets data fields from the input. Never
touches runtime fields (`_task_id`, `_listeners`, `_deleting`, etc.). Returns
`true` on success or `nil, "error"` on failure. Cross-object navigation uses
direct references resolved during `_apply()`.

**First-class fields**: domain objects store state as individual fields, not
cache-shaped bags. ConfigUnit has `state_value`, `build_dir_value`,
`last_configured`, `last_built`, `cmake_info`, `_variant`, `_tool_key`, etc.
Each domain object has a `serialize()` method that produces the cache-shaped
data table on demand, turning references back into keys.

**DataModel** (`data_model.lua`): deserialization orchestrator. Receives raw
parsed file data + current domain object arrays (never accesses Workspace
directly). Builds a deserialization context with resolver methods
(`ctx:project(key)`, `ctx:tool(mod_type, key)`, etc.). For each object type
in dependency order: identity-matches against existing, calls `_apply` or
creates new, registers in ctx for downstream objects. Returns new arrays or
an error. **Missing-build-dir reset** (spec §3.1 rule 7): `sync_build_dirs`
stats each cached build directory (via the injected `dir_exists` dep, one
stat per directory) and records those that are gone in
`ctx.missing_build_dirs`; `sync_profile_projects_and_config_units` then resets
the matching ConfigUnit's cached `configured`/`built`/`failed_*` state to
`unconfigured` so a build reconfigures from scratch. `unknown`/`deleting` are
excluded (async-deletion crash safety).

**Workspace arrays**: `_modules`, `_projects`, `_config_sets`, `_profiles`,
`_config_units`, `_profile_projects` are plain arrays after refresh. Runtime
callers iterate with `pairs()` or use `find_*` helpers for key lookups.

**Refresh vs mutation**: `refresh()` is only for external file changes
(FileTracker detects change → DataModel produces new arrays → Workspace swaps
them in). Mutation methods (task results, materialization, deletion) update
domain objects in place and call `_save_cache()` to persist. No round-trip
through files.

**Refresh dependency order** (each step depends on the previous):
0. Modules — no deps
1. Tools — needs Modules
2. Projects (+ Configurations) — needs Modules
3. ConfigSets — resolves Project + Configuration references
4. Profiles — resolves ConfigurationSet + Tool references
5. ConfigUnits — resolves Project + Tool + Configuration; a cached entry is
   matched back on the `(project, config)` identity (its `config_key`), and the
   unit adopts that entry's persisted `build_dir` rather than a recomputed path
6. ProfileProjects — resolves Profile + Project + ConfigUnit references
7. BuildDirs — domain objects for physical build directories with state
8. BuildDirRefs — reverse index from BuildDir paths
9. ArtifactRefs — reverse index from resolved output-artifact paths to the
   ConfigUnits that produce them (output-artifact conflict detection, §5.9)

**Module** (`module.lua`) wraps a stateless module function table (cmake.lua,
meson.lua, typescript.lua) as a per-workspace domain object. Owns the Tool
registry for its module type. No `_workspace` back-reference — pure domain
object. Created during `_sync_modules()`. `Project._module` replaces
`project.type` string for module identity (type string kept for display).

**Tool** (`tool.lua`) represents a toolchain (ninja-gcc-12, msvc-17-2022).
Owned by `Module._tools` registry, keyed by `tool_key`.
`Tool._module` references the owning Module domain object.
Created from async detection results AND from cached tool_data at startup.
For non-keyed modules (typescript), a single default Tool with nil key
exists. ConfigUnit, Profile, and Project carry `_tool` references alongside
legacy `tool` ToolRef tables. Accessor: `unit:tool_object()`,
`profile:tool_object_for(module)`.

**Configuration** (`configuration.lua`) represents a build variant (Debug,
Release, Debug-asan). Owned by `Project._configurations` registry, created
from module.info() output + loomworks.json user overrides. Separates generic
fields (name, variant, inherits, options, variables, `env`, overrides) from
module-specific data (`module_config`) — `env` (spec §1.3.3) is a generic field,
not a module field, and is serialized with the configuration. Inheritance uses Configuration object references resolved
within the project. ConfigUnit carries `_configuration` reference. Accessor:
`unit:configuration()`, `pp:configuration()`.

Configuration names are canonical, two-tier:

- **Auto-gen configs** carry `prefix:base` canonical names
  (`variant:Debug`, `preset:debug-custom`, `auto:default-entry-arm64-v8a`).
  `prefix` is module-chosen (see each module's `default_configurations`
  / `info()` for which prefixes it emits); `base_name` is the portion
  after the separator. `Configuration:is_auto_gen()` returns true iff
  `prefix ~= nil`.
- **User configs** have bare names without `:`. `config.validate`
  enforces the namespace rule.
- `Configuration.canonicalize(auto_configs, user_overrides, module_id)`
  is the shared transform each module calls from `info()` to produce
  a canonical-keyed dict. Auto-gens without an explicit `prefix` field
  fall back to the module id as prefix.

Two orphan signals live on Configuration for the UI layer:
`_source_missing` (this object is a stub created by
`Project:ensure_configuration` because something referenced a name
no live config backs; cleared on next `_update` that carries
`is_default`/`is_user`/`from_preset`), and
`unresolved_inherits_names()` (list of base names this config's
`inherits` couldn't resolve). UI renders source-missing configs and
unresolved inherits in `WarningMsg`.

**ConfigurationSet** owns activation: `cs:activate(tool_entry)` finds or
materializes a profile by property matching, never by computing a key.
`cs:ensure_profile(tool_entry)` materializes without activating.
`cs:configuration(project)` returns the Configuration object for a project.

**ConfigUnit** is the meeting point — Profile, Project, and task_tracker all
reference the same ConfigUnit for a given (project, configuration, tool) triple.
State changes on a ConfigUnit are immediately visible to all consumers.
ConfigUnit stores first-class fields (`state_value`, `build_dir_value`,
`last_configured`, `last_built`, `cmake_info`, `_variant`, `_tool_key`,
`_tool_data`, plus the resolved-artifact-set fields `_artifacts` and
`_overwritten_by`, §5.9) and carries direct references: `_project`, `_tool`,
`_configuration`, `_build_dir` (BuildDir object).

**BuildDir** (`build_dir.lua`) represents a physical build directory with cached
state (configured, built, failed). Separate from ConfigUnit (user intent).
ConfigUnit references a BuildDir via `_build_dir`. Orphaned BuildDirs have state
but no ConfigUnit pointing to them. Created during `sync_build_dirs()` from cache
entries; task completion handler creates new BuildDirs when needed. Workspace owns
`_build_dirs` array (all BuildDirs including orphaned). No raw cache data is
retained after deserialization — BuildDir objects are the source of truth.
BuildDir also carries the config unit's persisted `artifacts` (resolved
output-artifact set) and `overwritten_by` marker, so those survive a reload
alongside build state.

**Output-artifact conflicts** (§5.9) are a Workspace-level layer over the
`_artifact_refs` index (rebuilt each remerge alongside `_build_dir_refs`).
`artifact_conflicts_for(unit)` / `artifact_conflict_block(unit, force)` gate a
build that would clobber a still-`built` unit's shared output (the CLI refuses
with exit 1; the editor confirms via a dialog — both thread one `force`).
`_invalidate_overwritten_by(builder)` marks other built sharers `overwritten` on
a successful build (and clears the builder's own marker);
`_clear_stale_overwritten_markers()` (run after every index rebuild) drops a
marker once the two units no longer share an artifact. `resolve_artifacts` is an
optional module capability (cmake implements it); a module without it takes no
part in conflict detection.

**Target** wraps raw module detection data (type, dependencies, artifact)
into an object with query methods (`is_executable()`, `display_name()`) and
a `build()` method that delegates to the module. Stored on
`ConfigUnit.targets` via `set_targets()`. Runtime-only, recreated on each
parse. Back-references its owning ConfigUnit.

**LaunchTarget** represents a profile's selected default target. Resolves
a disk descriptor (`{ project, target }` from user.json/loomworks.json) into
direct object references (Project, ConfigUnit, Target). Created on demand
by `Profile:default_target()`. `deploy()` method executes deploy steps
from the launch config's `deploy` dict before launching — resolves sources
within the profile context, checks freshness, copies files.

**TestUnit** (`test_unit.lua`) is the interface for test discovery and
execution within a ConfigUnit. **CTestUnit** (`test_units/ctest.lua`)
wraps ctest for cmake projects — discovers targets via
`ctest --show-only=json-v1`, probes binaries for framework detection,
runs tests via ctest commands. Created lazily by the module's
`create_test_unit()` factory. ConfigUnit delegates all test operations
to its TestUnit instances.

**GTest** (`gtest.lua`) is a shared helper (not a TestUnit) containing
gtest-specific functionality: binary probing (`--gtest_list_tests`),
source location scanning (TEST macro grep with multi-line and
parameterized support), JUnit XML parsing, and filter construction.
Used by CTestUnit for framework detection and source mapping.

**Neotest adapter** (`neotest/init.lua`) bridges ConfigUnit's test
interface to neotest's adapter protocol. Uses cached test file/directory
sets for `is_test_file` and `filter_dir`. All adapter methods are
pcall-wrapped (neotest's nio coroutine context hangs on unhandled
errors). No `vim.fn` calls (deadlock in nio context). Deduplicates
`discover_positions` calls (neotest calls with different path formats
on Windows).

**loomtest** (`lua/loomtest/`) is a test-first test explorer independent
from loomworks. Discovers tests from the build system (not source files).
Integration with loomworks through `loomtest_adapter.lua` which bridges
ConfigUnit/TestUnit to the TestAdapter interface. Core modules: explorer
(Snacks.win tree UI), runner (overseer execution with streaming + XML
parsing), signs (gutter marks), inline (virtual text + vim.diagnostic).
See LOOMTEST.md for full specification.

---

## Testing

### Running Tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) with
busted-style assertions. A Makefile provides shortcuts:

```bash
make test                                    # run all tests
make test-file FILE=tests/core_spec.lua      # run a single test file
```

Or directly:

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

`tests/minimal_init.lua` bootstraps plenary and sets up the Lua path.

### Test Patterns

Tests use the constructor injection pattern described in Design Principles §5.

- **Unit tests** feed raw JSON strings to `core:setup()` via mock io, then
  assert on the resulting state (profiles, projects, active set).
- **Cache coherence tests** verify that every profile references valid cache
  entries and vice versa, using `assert_cache_coherent()`.
- **State machine tests** simulate task sequences (configure → build) and
  verify state transitions via ConfigUnit.
- **UI tests** are not implemented — sections are pure functions, so
  correctness is verified through core/cache tests.

### Key Mock Patterns

- `mock_io.read_json(path)` returns pre-built data tables
- `mock_io.write_json(path, data)` captures writes for assertion
- `mock_io.rm_rf(path)` records deletions
- `mock_modules.get(type).info(path, config)` returns canned module info

---

## Standalone Runner & Distribution

Fulfils [specification.md §16](spec/core/headless.md). One codebase, two runtime
hosts; the domain and module layers are identical between them.

### Runtime host

The `vim` global is provided by either Neovim (the editor, and
`nvim --headless -l` for tests) or a standalone LuaJIT + libuv host
(**luvi**) plus a shim (`lua/loomworks/shim/`), loaded via
`if not vim then require("loomworks.shim") end`. The shim:

- vendors Neovim's pure-Lua modules (`shared.lua`, `fs.lua`) verbatim,
- maps `vim.uv` to `require("luv")`,
- hand-writes the native-backed surface: `json`, `system` (over
  `uv.spawn`), `fn.{executable,exepath,mkdir,has,getcwd,fnamemodify}`,
  `v.shell_error`, `schedule` (drained by `uv.run()`), `notify` / `log`.

The JSON shim MUST reproduce Neovim's `empty_dict` / `NIL` / array-vs-object
semantics (spec §16.1). A differential test uses headless Neovim as the
oracle, which doubles as the drift guard when new `vim.*` usage appears on
the build path.

### Entry point

`lua/loomworks/cli.lua`: argument parse → root discovery (walk up from the
cwd for `loomworks.json` or `.nvim/loomworks.user.json`, stopping at a git
working-tree boundary so a fresh worktree never binds to a parent checkout —
spec §1.1) → `Workspace.assemble` → `Workspace.new` +
remerge → resolve the named profile → for each buildable ConfigUnit, the
cold path (detect → configure) or warm path per spec §16.4 →
`overseer.build_spec_for(unit)` → spawn via a libuv runner that replaces
overseer.nvim. An empty task `env` inherits the parent environment (it never
replaces it, which would drop `PATH`).

### v1 command surface

- `lw build [profile]` — resolve and build a profile.
- `lw test [profile] [--junit <file>] [-- args…]` — build the test target and
  run it; real exit code. Args after `--` forward to the native batch runner
  (`-j N` / `--num-processes N`); `--junit <file>` requests JUnit XML for CI.
  `plan_profile_test` threads both into each `TestUnit:run_command_all(opts)`:
  ctest maps `--junit` to `--output-junit` (writes directly), meson reports its
  fixed `meson-logs/testlog.junit.xml` as `junit_out` and the CLI copies it to
  the requested path — so the core stays module-agnostic. One file per unit
  (label-suffixed when a profile runs several).
- `lw profile list` — list profiles (name, configuration set, tools) and flag
  which are buildable in this host vs editor-only (`lw profiles` is an alias).
- `lw run <profile> [target] [-- args…]` — non-debug launch (build → deploy →
  execute). The target is the profile's default (§8.6) when unnamed, else a
  named build target or command launch config; `project:name`, `--project`,
  and `--target`/`--launch` disambiguate. Args after `--` are forwarded to the
  program. Routes through the editor's `LaunchTarget` seams
  (`resolve_launch_spec`, `deploy_sync`) so headless and editor launches stay
  identical; the runner only swaps the executor (direct `vim.system` vs
  overseer). Build-target launches set up a run environment (§8.7): core
  prepends the build tree's shared-library output dirs plus the module's
  `runtime_path()` (toolchain runtime) to `PATH`. `ConfigUnit:run_env()` is the
  single source of truth (composed via `loomworks.runenv`); both target launches
  and the test runners use it, so a DLL/`.so`-dependent executable resolves its
  siblings identically whether run or tested. `ctest`, unlike `meson test`, does
  not set this up itself, so `lw test` must parse targets before planning.
  - **Unified dispatch seam.** After the profile + target resolve, both the
    normal run and its two modifiers share one tail — `cli._run_launch_target`
    — which validity-gates, deploys, and calls `LaunchTarget:resolve_launch_spec`
    to get one normalized `{ cmd, args, cwd, env }` for **either** a command
    launch config **or** an executable build target (the dispatch already lives
    in `resolve_launch_spec`; the CLI does not branch on target kind). It then
    reports or executes:
    - `--prefix <cmd>` (spec §16.17 "Launch prefix") builds the argv
      `{ prefix…, cmd, args… }` via `cli._build_run_argv` and execs it through
      the SAME inherited-stdio path (`run_spec`) an unprefixed run uses, in the
      resolved cwd/env — so an interactive wrapper (gdb/valgrind) drives the tty.
      Prefix tokens are supplied combinably (a shell-word-split string via
      `cli._shell_split`, and/or a repeatable flag); a prefix on a device target
      is refused. The wrapper's exit status is the invocation's.
    - `--print`/`--dry-run` (spec §16.17 "Command inspection") skips execution
      and emits the resolved invocation via `cli._emit_run_print`: a
      POSIX-sh-quoted line (`cli._posix_sh_quote`) by default, or `=json`
      (`{cmd:[argv],cwd,env}`). The env is **overrides only** —
      `cli._launch_env_overrides` diffs the resolved run env against the
      inherited environment, so a full build-target run env collapses to just its
      contribution. An unresolved build-target artifact is reported (non-zero),
      never guessed. Under `--print` the (default) build streams to stderr
      (`run_build_steps` quiet mode → shim `stdio = "inherit_err"`) so stdout
      carries only the report line for `$(lw run --print)`.
    - `--no-build` skips the build+deploy pair (run/inspect what is already
      built).
- `lw target [list] [profile]` / `lw target set [<profile>] <target>` /
  `lw target clear [profile]` — list a profile's launchable targets (read-only
  introspection, spec §16.18: command launch configs plus configured build
  targets, default marked `*`), or set/clear its default launch target (writes
  `user.json`; spec §16.9 authoring). Listing defaults to the active profile
  even in `--no-input`; `set`/`clear` keep the CI-determinism guard (one-operand
  = active profile interactively, explicit `<profile>` required non-interactively).
  Shared seam `collect_targets` also feeds the `lw status` Targets section.
- `lw sdk <types|list|add|remove>` — declare toolchain installations that
  detection cannot find (a compiler at an arbitrary path, a cross-compiler).
  Thin wrappers over `Workspace:add_sdk` / `remove_sdk`; the declared SDK
  produces a kit, so it appears in `lw tools` and is pinnable by
  `lw profile create`. `--force` registers a path that fails identification
  (spec §10.1). Provider discovery scans runtimepath, which the standalone host
  lacks, so the CLI additionally probes the providers bundled with core.
- `lw profile query <profile> <project> <field>` — read-only introspection
  (spec §16.18): prints one machine-readable fact (`build-dir` / `config` /
  `state` / `tool` / `cache` / `variables[.<name>]`) for scripting, e.g.
  locating CI artifacts. No build. `cache` is the `(profile, project)` compiler
  cache status — `Profile:compiler_cache_status(pp)` with the `Cache: ` prefix
  stripped (the same string `render_cache_line` prints for `lw status` and
  `lw profile show`); empty for a project with no C/C++ compiler cache.
- Profile/tool **selection** (spec §16.3) is a boundary-anchored matcher
  (`merge.match_profile` for profile keys, `Module:find_tool` for tool keys):
  a version-truncated selector (`ninja-clang-18`) resolves to the highest
  matching patch and never crosses a version boundary. `build`/`test`/`run`/
  `query` and `profile create` all route through it.
- Management/authoring commands (spec §16.9, write the working copy; reach
  `loomworks.json` on `lw publish`): `lw init [--name <name>]`,
  `lw workspace rename <name>`, `lw project <add|remove|rename>`,
  `lw config <add|set|unset|remove>`,
  `lw configset <create|map|unmap|remove>`, `lw profile create`,
  `lw launch <add|set|remove>`, and per-item `lw <kind> publish`. Each delegates
  to the same atomic `Workspace` mutation the editor uses (e.g. project rename →
  `Workspace:rename_project`, workspace name → `Workspace:rename_workspace`).
- **Working-copy pull** (spec §16.25): `lw pull [<source>] [--dry-run]` folds
  another checkout's working copy into the current one so a fresh `git worktree`
  inherits its config. `cli._plan_pull` resolves the source (default = the main
  worktree via the extracted `cli._main_worktree`, reused from the status hint),
  reads the foreign `user.json` with the stateless `loomworks.user` loader (the
  in-process workspace is untouched), and `cli._pull_merge` unions the two
  working copies **item-level, source-wins** — the deliberate opposite winner
  from `workspace.merge_configs` (target-wins). Synced set: projects,
  configuration_sets, profiles, sdks, default_target, and the nested debug/lsp
  settings maps (those two `pull_deep_union`'d per key so siblings survive).
  Excluded (target keeps its own): the active profile, the workspace `name`, the
  per-machine `device` map, and all cache/build state. It then writes via the
  atomic `user.save` path only; it never publishes. Runs before the
  workspace-required guard so it works in a worktree that has no workspace of its
  own yet.
- **Convention migration** (spec §16.19): `lua/loomworks/migrate.lua` holds a
  registry of named rules, each separating `plan` (what would change) from
  `apply` (change it), so `lw migrate --check` can lint without write access
  and the applying path can show every before/after first. Rules rewrite form,
  never meaning, and report anything they cannot rewrite safely instead of
  guessing. Rewrites go through `Project:save_configuration` like any other
  mutation; `lw migrate` then republishes, since `loomworks.json` is
  regenerated from the working copy rather than patched.
- **Health / suggestions** (spec §16.31): `lw health` (`cli.cmd_health`) lists
  the workspace's advisory items in full via `suggestions.collect_health(ws)`
  (passive + on-demand providers) — read-only, spawns nothing, always exits 0
  (advisory, never a diagnostic). It renders informational items (`kind == "info"`,
  e.g. "Compiler cache: using sccache") distinctly from actionable ones. `ws` may
  be nil: `cmd_health` passes whatever workspace it resolved (none in a plain
  dir), and the workspace-independent providers (update availability, channel
  override) still report, led by the same worktree/init hint the overview shows —
  so `lw health` outside a workspace is no longer empty. The passive
  `N suggestions — run lw health` count line uses
  `suggestions.count_actionable(ws)` (passive providers, actionable items only),
  so a frequently-rendered status page never performs the network I/O the
  update-check provider does — that check runs solely on an explicit `lw health`,
  and an offline/API failure yields nothing — and the affirmative cache-status
  info item never inflates the count. The `lw status` overview shows only that
  compact count line (the editor status page mirrors it). `lw status --cache-stats`
  additionally folds in the resolved cache tool's own stats (`ccache -s` /
  `sccache --show-stats` via `cli._cache_stats`) — off by default because it
  spawns the tool.
- **Suggestion cache** (`health_cache.lua`, spec §16.31): the suggestion results
  are cached in `.nvim/loomworks.health.json` — an internal advisory cache with
  its OWN schema version (`SCHEMA_VERSION = 1`), deliberately decoupled from the
  build-state cache (`loomworks.cache.json`'s version + deletion safety). Two
  tiers over one file: a **local tier** `{ items, computed_at, key }` (the passive
  providers' results) and a **network tier** `{ items, computed_at }` (the
  on-demand providers'). The `key` is a cheap in-memory fingerprint
  (`suggestions._local_key(ws)`) of exactly the passive-provider inputs — platform,
  each project's key/module/`caches_cpp`/explicit `cache` values, and the active
  profile's identity + resolved tool keys — with NO PATH probe folded in, so it
  stays cheap to recompute on every render. `suggestions.collect(ws)` (the passive
  count) reads the cache, recomputes the local tier only when it is absent or its
  key changed (lazy compute-on-first-`lw status`), rewrites it, and folds in the
  cached network items informationally — but NEVER computes the network tier, so a
  passive render never touches the network. `suggestions.collect_health(ws, opts)`
  (`lw health`) always recomputes the local tier and refreshes the network tier
  when it is absent, older than `NETWORK_TTL` (~24h), or `opts.force` is set
  (`lw health --force`/`--refresh`); otherwise it reuses the cached network tier so
  back-to-back health runs don't hammer the API. Reads use an injected wall-clock
  (`suggestions._clock`, `os.time` — persist-across-process, not the monotonic
  `deps.clock`) and the workspace's io dependency; a missing/corrupt/older-schema
  file is treated as empty and recomputed (never an error), writes are atomic. No
  workspace → no file to key against, so both paths run providers live without
  caching. No background/async network refresh is done here — a possible future
  enhancement; the network tier is refreshed strictly on `lw health`.

Out of scope for the standalone: debug launch (DAP, needs nvim-dap) and device
install / launch. Deploy sources outside the active profile and
pre-build "deploy feeds build" ordering are a known limitation (a headless run
builds the profile up front, then runs both deploy phases). No-argument
`lw build` resolves the profile as: explicit argument → `user.json` active
profile (if present) → the single published profile → otherwise an error
listing candidates.

### Module bundling and acquisition

The loomworks distribution bundles the core modules (cmake, meson, shell,
typescript). External module plugins (e.g. OHOS / harmony) ship separately.
In the **editor**, they arrive through the plugin manager (on the runtimepath),
so discovery is free. In the **standalone host**, `lw module install <name>`
acquires them (spec §16.20) — see "Module acquisition" below. A profile whose
module is present in neither place degrades per spec §16.8.

### Host bootstrap and source resolution

`lua/main.lua` is the fused **bootstrap** — the only Lua baked into the host
binary. It carries no behavioral logic; it (a) reads host config, (b)
resolves the system-Lua source per spec §16.11, (c) for the release source,
ensures a verified bundle is present (§16.12–16.13), (d) installs package
searchers + `nvim_get_runtime_file` discovery pointed at the resolved Lua
root **and at each acquired module's `lua/` root** (via
`_G.__loomworks_module_roots`, kept in lockstep between the require searcher
and the shim glob), then (e) `require`s the system entry (`loomworks.cli`).
Source precedence:

1. `--dev[=PATH]` flag or `LOOMWORKS_LUA` env → a working tree on disk
   (verification skipped);
2. host config `default_source = "dev"` with a configured `dev.lua` path →
   same;
3. otherwise the **release** root — the highest-versioned verified bundle
   under the data dir.

The verifier and the trusted public key live in the bootstrap, never in the
bundle they check (spec §16.12).

### Host binary

The host is **luvi** (LuaJIT + libuv + OpenSSL, statically linked) with the
bootstrap fused in via `luvi <bootstrap> --output lw`. It is generic and
changes rarely — only when the runtime surface changes (a libuv/OpenSSL bump
or a new native capability). CI builds one host per platform:
`lw-linux-x86_64`, `lw-macos-arm64`, `lw-macos-x86_64`,
`lw-windows-x86_64.exe`. Because `luvi --output` fuses the *running* luvi,
each asset is built on its own OS in a CI matrix (no cross-fusing).

### Release layout

A GitHub Release (tag on `master`) carries:

- the host binaries (above);
- `loomworks-lua-<ver>.zip` — the system Lua (`lua/loomworks/**`, shim,
  modules): everything *except* the bootstrap;
- `manifest.json` — release version, `min_host_version`, and a SHA-256 for
  every asset;
- `manifest.json.sig` — a detached **ECDSA P-256 + SHA-256** signature over the
  exact bytes of the manifest.

The manifest is the single trust anchor: its signature vouches for every
file's hash (spec §16.12). ECDSA-P256 (not Ed25519/minisign) because luvi's
bundled OpenSSL verifies it directly — its `verify` needs a digest, which is
the classic RSA/ECDSA flow, whereas Ed25519 is a one-shot the binding doesn't
expose. The verifier lives in `lua/boot/verify.lua`; see below.

### On-disk layout (per user, no admin)

```
<data>/loomworks/            (%LOCALAPPDATA%\loomworks | ~/.local/share/loomworks)
  bin/lw[.exe]               the host binary (on PATH)
  lua-<ver>/                 verified, extracted release bundles (versioned)
  modules/<name>/lua/**      acquired modules (spec §16.20); .module.json record
  cache/tools.json           machine-level tool cache
<config>/loomworks/config.json   dev source + default_source (spec §16.11)
```

Release bundles are versioned directories; activation writes a *new*
`lua-<ver>/` and never overwrites a running one (spec §16.13). "Highest
valid version wins"; older bundles are GC'd; rollback = prefer the previous
directory.

### Acquisition & self-update

`lw self-update` fetches `manifest.json` + `.sig`, verifies the
signature with the embedded key, downloads any newer `loomworks-lua-*.zip`,
re-checks its hash against the manifest, extracts to a new `lua-<ver>/`, and
switches the active version atomically. If the manifest's `min_host_version`
exceeds the running host, it reports that a new host is required rather than
running incompatible Lua (spec §16.14). Downloads are proxy-aware; because
integrity rests on the signature, a MITM'd or cert-relaxed transport cannot
inject code (spec §16.12). Self-update is a management operation and never
runs as part of `lw build` (spec §16.9, §16.13).

**Update channels** (spec §16.29). `self_update` first resolves an update
channel — `update.resolve_channel(opts)` with precedence `opts.channel`
(from `lw self-update --channel`) > `LOOMWORKS_CHANNEL` env > the `channel`
config key > `"stable"` (unknown value → error). Only `stable` and `unstable`
are valid.

- **stable** keeps the existing base, `…/releases/latest/download`, which
  GitHub already resolves to the newest *non-prerelease* — so stable is a
  no-op change.
- **unstable** queries the GitHub **releases API**
  (`https://api.github.com/repos/samienne/loomworks.nvim/releases`, newest-first)
  via `download.fetch` (which now takes an `Accept` + `User-Agent` header),
  parses it with `boot.json`, and takes the newest **non-draft** entry
  (pre-releases *included*). Its `tag_name` (leading `v` stripped) is validated
  with `pin.valid_version` **before** it is interpolated into any URL — a
  network-derived tag is never trusted into a path (defense in depth, same trust
  boundary as `lw.pin`). The bundle is then fetched from
  `versioned_base(version)` (`…/releases/download/v<ver>/`) and verified by the
  identical manifest-signature + artifact-hash chain — the channel changes only
  *which* release, never *how* it is trusted.

An explicit release-source override (`opts.url` / `LOOMWORKS_RELEASE_URL` /
`release-url` config) **supersedes** the channel: the mirror is used as-is and
the API is never called (the channel governs only the default origin). A pin is
independent and stronger still (`main.lua` redirect + `ensure_version`): a
pinned invocation acquires exactly its version+hash and consults no channel.
`paths.version_gt` is semver-aware so a pre-release orders below its release —
`installed_releases` ordering and `gc` never retain a pre-release over the full
release it precedes. `lw version` prints the resolved channel.

### Module acquisition

`lw module install|update|remove|list` extends the host's module set from a
**curated index** (spec §16.20). `boot/modules.lua` drives it, reusing the
self-update primitives: `download.fetch` for the index and the archive,
`verify.sha256_hex` for the pinned-hash check, `update.extract_zip` (miniz) for
unpacking.

- **Index** — a JSON document (`modules.json`) fetched from the loomworks repo
  over HTTPS (default: raw on the default branch; override with `module-index`
  config / `LOOMWORKS_MODULE_INDEX`, a local path works offline). Shape:
  `{ schema, modules: { <name>: { version, api_version, url, sha256,
  description?, repo?, brings? } } }`. The index is trusted because of its
  channel; the *artifact* is trusted because its bytes match `sha256`.
- **Artifact** — a pinned-tag source archive **zip** (GitHub codeload style),
  so no tar dependency and `extract_zip` is reused. Install keeps only the
  shipped `lua/` tree (module + any SDK providers / progress parsers it
  brings), renames it into `<data>/loomworks/modules/<name>/lua`, and writes a
  `.module.json` install record (version, api_version, verified sha256, url,
  brings). The archive's single top-level wrapper dir is stripped.
- **Version gate** — the index records each module's plugin-interface version
  (§8.0); an incompatible entry is refused *before* download (`M.compatible` /
  `M.incompatible_reason`, distinguishing "update lw" from "no compatible
  module release yet"). Same strict-equality rule the loader applies, moved
  earlier. `lw module update --all` skips an incompatible module with a note
  rather than failing the run.
- **Resolution** — installs are separate from `lua-<ver>/`, so `self-update`
  never disturbs them and vice-versa. They become resolvable because the
  bootstrap adds each `modules/<name>/lua` to the require searcher and the shim
  glob (see "Host bootstrap"). A freshly installed module is picked up by the
  *next* `lw` invocation, not the current process.

`lw module` is standalone-only; it requires `boot.*` (the luvi host), so under
the nvim-hosted fallback it errors with that hint.

### Repo-local launcher & version pin

`lw bootstrap` commits a launcher + pin so a repo runs a fixed, verified `lw`
with no prior install (spec §16.21–16.24). Layers:

- **`boot/pin.lua`** — pure logic: parse/serialize `lw.pin` (`key = value`, no
  JSON), select the host-binary asset for the platform (`HOST_ASSETS` keyed by
  `<os>/<arch>` → the real release asset names), walk up for the pin root, and
  `decide{…}` the redirect action (`in-process` | `redirect` | `bypass` |
  `no-pin`). No I/O beyond stat, so it is unit-tested exhaustively.
- **`boot/bootstrap.lua`** — `bootstrap` / `update`: fetch the release's
  **signed** `SHA256SUMS` (`versioned_base` → `…/releases/download/v<ver>/` on
  GitHub, flat on a mirror), verify `.sig` against the embedded key, select the
  host-binary + bundle hashes into `lw.pin`, write `lw.sh` / `lw.cmd` (templates
  live here as the single source of truth), and append `.nvim/cache/` to
  `.gitignore` idempotently (append-only — never rewrites existing content).
- **`boot/update.lua`** — `ensure_host_binary` (fetch + pinned-hash-verify a
  host binary into `.nvim/cache/`) and `ensure_version` (fetch + verify + extract
  the bundle into **repo-local** `.nvim/cache/lua-<ver>/`). Both reuse
  `download` + `verify.verify_file_sha256` + `extract_zip` + `rename_with_retry`;
  the pinned committed hash is the trust anchor (no manifest needed at runtime).

`main.lua` wires two entry points around the existing source resolution:

- **Pinned context** — when the `LOOMWORKS_PINNED=<ver>` sentinel is set (by a
  launcher script or the redirect), the host provisions the pinned bundle via
  `ensure_version` and points `luaroot` at the repo-local `lua-<ver>/`, then runs
  normally. The sentinel also blocks any further redirect (anti-recursion).
- **Redirect** — a global host on a workspace op (`build`/`run`/`test`/`clean`/
  `configure`) consults `pin.decide`; on `redirect` it `ensure_host_binary`s the
  pinned binary, sets the sentinel + `LW_ROOT`, and `uv.spawn`s it with inherited
  stdio, propagating the child's exit code. `--no-pin`, `LOOMWORKS_LW`, and a dev
  source bypass; `version`/`self-update`/`install`/`bootstrap`/`update` are host
  commands handled before the redirect, so they never redirect.

Security: the origin is fixed in the host (user-overridable only via
`LOOMWORKS_RELEASE_URL`); the pin carries a version + hashes, never a URL; the
hash check is mandatory even under `--insecure` TLS; and the global host never
executes the repo's `lw.sh`/`lw.cmd` — it resolves the pin declaratively and runs
the official binary it fetched itself. Worst case a malicious pin forces an
authentic older release, never unofficial code.

### Install security

The host cannot verify itself (the verifier is inside it), so its own integrity
is established out-of-band (spec §16.15) — and only for the first install; every
later hop verifies against a key or pinned hash already on the machine. Two
independent anchors cover that first hop. **Build provenance** is the stronger:
each host binary is attested by `actions/attest-build-provenance` and recorded
in Sigstore's public transparency log, so `gh attestation verify` confirms it
came from this repo's release workflow with a trust root *independent of the
release host* — the one check that survives tampered release assets. The keyless
**signed `SHA256SUMS`** route is the fallback where `gh` is absent: the release
signs the hash list with the release key, and the documented install verifies
the `.sig` against the public key from the README, then checks the binary's
hash. That route is trust-on-first-use on the README-hosted key — it stops a
swapped binary (the private key never leaves CI) but is not an independent
anchor the way provenance is. Either way the documented install is a transparent
one-liner — verify, then run the verified binary's `lw install`, which copies
itself to a per-user location (`~/.local/bin/lw`, or `%LOCALAPPDATA%\Microsoft\
WindowsApps\lw.exe` on Windows — already on PATH), ensures PATH (prompting;
`-y`/`--no-modify-path`), and fetches the first bundle. No `curl | sh`.

Bundle trust rests on **signature verification, not transport**: the host
embeds an ECDSA P-256 public key and verifies the signed manifest before
executing any bundle Lua; a hash mismatch or bad signature aborts. The private key is
generated offline and held only as a tag-gated CI secret; the production
public key is injected into `boot/verify.lua` at release-build time (the
committed source carries a throwaway test key, so the verifier tests are
hermetic). Verification uses luvi's built-in OpenSSL, so there is no bundled
crypto to maintain. The one-line installer
(`install.sh` / `install.ps1`) is deferred — until then a host binary is
placed on PATH manually (or built from a checkout) and `lw self-update`
fetches and verifies the first bundle. `lw` installs only the runtime; it
detects, never installs, C/C++ toolchains.

### File additions

`lua/main.lua` (bootstrap), `lua/boot/` (bootstrap-only modules: `paths.lua`
data-dir/version/mkdir helpers + acquired-module enumeration, `json.lua`
decode + small encode, `verify.lua` ECDSA-P256 manifest verifier, `download.lua`
curl/local fetch, `update.lua` self-update + miniz extraction + pinned
provisioning (`ensure_host_binary` / `ensure_version`), `install.lua`
self-install, `modules.lua` module acquisition, `pin.lua` pin parse / asset
selection / redirect decision, `bootstrap.lua` `lw bootstrap`/`update` + the
launcher-script templates), `lua/loomworks/shim/`, `modules.json` (the curated
module index), `bin/lw`, `bin/lw.cmd` exist. The bootstrap intercepts the host
commands `lw version` / `lw install` / `lw self-update` / `lw bootstrap` /
`lw update`, and redirects workspace ops to a repo's pinned `lw`; `lw module` is
a CLI command (system Lua) that calls into `boot.modules`.
The release pipeline is `scripts/release/build_bundle.sh` (bundle + signed
manifest) and `scripts/release/fuse_host.sh` (inject the production key + fuse
one host), driven by `.github/workflows/release.yml` on a `v*` tag: a matrix
builds a host per platform (each fetching the matching luvi), a job builds the
signed bundle, and a publish job generates and signs `SHA256SUMS`, attests build
provenance for the host binaries, and attaches everything to a GitHub Release. The maintainer supplies the signing key (see `keys/README.md`).
`make dist` is a local dry-run. Installation is the transparent
download-verify-`lw install` one-liner (spec §16.15), so no hosted installer
script is needed.

---

## File Layout

```
loomworks.nvim/
├── CLAUDE.md                          Project context for AI
├── ARCHITECTURE.md                    This file
├── specification.md                   Core behavioral specification
├── spec/
│   ├── ui.md                          Status page, highlights, winbar
│   ├── modules/                       Per-module specs (cmake, meson, shell, typescript)
│   ├── integrations/lsp/              Per-LSP-server specs (clangd, …)
│   ├── integrations/debug/            Per-DAP-adapter specs (codelldb, cppdbg, pwa-node, …)
│   └── sdks/                          Per-SDK-provider specs (cpp_compiler, …)
├── README.md                          User-facing documentation
├── BACKLOG.md                         Deferred features and design notes
├── lua/
│   ├── loomworks/
│   │   ├── init.lua                   Public API facade
│   │   ├── core.lua                   Infrastructure layer (I/O, deps, setup)
│   │   ├── workspace.lua              Domain container (Workspace class + static helpers)
│   │   ├── file_tracker.lua           uv.fs_poll file watcher
│   │   ├── io.lua                     Atomic file read/write
│   │   ├── config.lua                 loomworks.json parse/validate
│   │   ├── user.lua                   user.json read/write
│   │   ├── cache.lua                  cache.json read/write
│   │   ├── merge.lua                  Three-file merge → ActiveSet
│   │   ├── events.lua                 Event/signal system
│   │   ├── tool.lua                    Tool domain object (per-module toolchain)
│   │   ├── configuration.lua          Configuration domain object (per-project variant)
│   │   ├── config_env.lua             Configuration `env` resolution (chain + family overrides)
│   │   ├── configuration_set.lua       ConfigurationSet class (owns activation)
│   │   ├── profile.lua                Profile + ProfileProject classes
│   │   ├── project.lua                Project class (owns Configuration[])
│   │   ├── config_unit.lua            ConfigUnit: user intent (project+config+tool)
│   │   ├── build_dir.lua             BuildDir: cached build artifacts for a directory
│   │   ├── device.lua               Device: physical/emulated deployment target
│   │   ├── launch_target.lua         LaunchTarget: profile's default build/launch/debug target
│   │   ├── target.lua                Target: module-detected build target (cmake exe, etc.)
│   │   ├── debug.lua                 DAP integration: config builder, adapter resolution
│   │   ├── session_tracker.lua       Unified launch/debug lifecycle manager
│   │   ├── deploy.lua                Deploy step resolution, freshness, execution
│   │   ├── variables.lua             Project variable resolution + validation (incl. reserved `cache` policy)
│   │   ├── reserved_compiler.lua     Reserved compiler keys (tool owns the compiler)
│   │   ├── compiler_cache.lua        Compiler-cache launcher resolution (policy→binary, PATH-gated)
│   │   ├── suggestions.lua           Advisory suggestion framework (`lw health`, status count line)
│   │   ├── health_cache.lua          Suggestion-result cache (`.nvim/loomworks.health.json`, two tiers)
│   │   ├── operation.lua              Operation class (profile action tracking)
│   │   ├── cmake_kits.lua             CMake tool detection (MSVC/VS; delegates gcc/clang)
│   │   ├── cpp_compilers.lua          Shared C/C++ compiler detection + arbitrary-path probe
│   │   ├── msvc.lua                    Shared MSVC/VS discovery: vswhere installs, vcvars env, clang-cl
│   │   ├── device_log.lua              Client-side device-log view (parser, filter, ring buffer, bottom-split)
│   │   ├── types.lua                  LuaCATS type annotations (not loaded)
│   │   ├── overseer.lua               Overseer template provider + launching
│   │   ├── paths.lua                  Path helpers: is_absolute + artifact_path (joins build_dir+artifact, passes an absolute artifact through unchanged)
│   │   ├── lsp.lua                    LSP registry + dispatcher (runtime-path discovery, setup_servers, get_status)
│   │   ├── integrations/
│   │   │   └── lsp/
│   │   │       └── clangd.lua         clangd integration (build_config, function-based cmd/root_dir, auto-restart)
│   │   ├── fidget.lua                 fidget.nvim progress integration
│   │   ├── config_editor.lua           Legacy JSON read-modify-write (not used at runtime)
│   │   ├── modules/
│   │   │   ├── init.lua               Module registry, detection orchestration
│   │   │   ├── cmake.lua              CMake module (full v1)
│   │   │   ├── meson.lua              Meson module (full v1)
│   │   │   └── typescript.lua         TypeScript shim
│   │   ├── progress/
│   │   │   ├── init.lua               Progress parser registry
│   │   │   └── ninja.lua              Ninja [n/m] output parser
│   │   └── ui/
│   │       ├── status.lua             Status page wiring
│   │       ├── view.lua               Window lifecycle via Snacks.win
│   │       ├── dialog.lua             Snacks.win dialog helper
│   │       ├── tree.lua               Foldable tree widget
│   │       ├── actions.lua            Action factories + delete dialog
│   │       ├── launch_editor.lua     Launch config editor (command, args, env, deploy)
│   │       ├── path_editor.lua        Reusable segment-based path editor dialog
│   │       ├── deploy_editor.lua     Deploy step editor (segment path + source picker)
│   │       ├── variable_editor.lua   Variable declaration editor (name, type, default)
│   │       ├── config_editor_dialog.lua  Configuration editor (inherits, options, variables)
│   │       ├── project_browser.lua   Directory browser for adding projects
│   │       ├── helpers.lua            Shared formatting
│   │       └── sections/
│   │           ├── diagnostics.lua    Diagnostics section (errors + warnings)
│   │           ├── tasks.lua          Tasks + build-dir locks (recovery surface)
│   │           ├── profiles.lua       Profiles section
│   │           ├── orphaned.lua       Orphaned Items section (configs + stray dirs)
│   │           ├── config_sets.lua    Configuration Sets section
│   │           ├── projects.lua       Projects section
│   │           ├── lsp.lua            LSP section (clients + Reset action)
│   │           └── debug.lua          Debug Adapters section
│   ├── overseer/
│   │   └── component/
│   │       └── loomworks/
│   │           └── task_tracker.lua   Overseer component for task lifecycle
│   └── lualine/
│       └── components/
│           └── loomworks.lua          Winbar component
├── plugin/
│   └── loomworks.lua                  Auto-load entry point
└── tests/
    ├── minimal_init.lua               Test harness bootstrap
    └── *_spec.lua                     Test files
```
