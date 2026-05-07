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
6. **Modules** (cmake, harmony, typescript) know nothing about profiles, UI, or
   overseer. They implement the module interface (validate, info, tasks,
   inspect, detect_tools) and operate on project paths and config data.
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
| `core.lua` | Dependency table (`_deps`), workspace lifecycle (`_state`, `_setup_error`), async setup (`setup`, `_on_files_read`), project validation (`_validate_projects`), nuke_cache, delete_user_prefs, `_safe_nvim_path`, `project_for_buf`, shutdown. Thin delegation wrappers forward to Workspace for init.lua callers | Hold domain registries; contain business logic; do I/O directly; know about UI |
| `events.lua` | Pub/sub system: `on()`, `off()`, `emit()` | Hold domain state; know about specific event semantics |

### Domain Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `workspace.lua` | **Workspace class**: all object registries (`_projects`, `_profiles`, `_config_sets`, `_profile_projects`, `_config_units`, `_operations`, `_tools_by_type`, `_active_set`), tool state (`_tool_state`, `_tool_waiters`), delete waiters, build dir reverse index (`_build_dir_refs`: normalized dir → set of cache keys, rebuilt in `_sync_build_dir_refs()` during remerge), build dir operation locks (`_build_dir_locks`: per-dir exclusive/shared locks with FIFO queue, `acquire_build_dir_lock`/`release_build_dir_lock`). Shared baseline (`_shared_baseline`: raw parsed loomworks.json, updated on load and `:w`). Business logic: remerge (per-configuration merge of user.json + loomworks.json), `_sync_*`, `_save_cache`, `_save_config` (publish to loomworks.json), `_save_user` (working copy), `_serialize_config`, `publish()` (`:w` handler — full regen), `publish_one(item)` (per-item partial loomworks.json write — preserves untouched entries), `revert_to_baseline()` (`:e!` handler — data-preserving force revert; locally-added items demote to `local`), `revert_one(item)` (per-item baseline restore / removed-upstream demote), `_publishable_to_shared` (transitive effective-intent closure, used by serialization), `_mark_removed_upstream(old_baseline)` (session flag set after baseline change, cleared on publish/revert), `create_operation`, `execute_deletion`, `record_task_result`, `_scan_tools_async`. Modified computation: `is_project_modified`, `is_config_modified`, `is_config_set_modified`, `is_profile_modified`, `has_any_modified`. Mutation methods: `add_project`, `remove_project`, `add_configuration_set`, `remove_configuration_set`, `update_config_set_mapping`, `rename_project_configuration` (atomic rename with cache migration), `create_profile`, `activate_profile`, `upgrade_profiles_for_tool`, `downgrade_profiles_from_tool`. Preview: `compute_downgrade_preview`. Query methods: `query_available_configs`, `map_variant`, `generate_default_config_sets`, `get_module`. File tracking: `_start_tracking`, `_stop_tracking`, `_on_file_changed` (snapshots old baseline before remerge, calls `_mark_removed_upstream`, always saves user.json so sticky intent survives restart), `reload_config`. **Static helpers** (on the module table, not the class): `resolve_root`, `paths`, `assemble` (pure), `create_workspace_config` (bootstrap) | Do I/O directly (delegates via `_core._deps`); know about UI; render anything |
| `merge.lua` | Three-file merge algorithm, profile collection, orphaned project detection, tool detection (sync and async) | Mutate state; do I/O; depend on core.lua or workspace.lua |
| `configuration_set.lua` | ConfigurationSet class: identity-preserving with `_update()`, owns activation (`activate()`/`ensure_profile()`), property-based profile lookup (`find_profile()`), resolves Project references internally. `update_mapping()` cascades `_mark_user_owned` to the set, the project, and the new config (specification.md §2.4 implicit cascade-on-use). References Workspace via `_workspace` | Own state beyond config data; do I/O |
| `profile.lua` | Profile and ProfileProject classes (tools dict keyed by Module object, `tool_object_for(module)` accessor), status aggregation, plan_deletion, activate/deactivate. `Profile:activate()` cascades `_mark_user_owned` through the profile, its config set, and the set's mappings — so user.json is self-contained for the active profile. Profile resolves mappings + ConfigurationSet reference in `_update()`. ProfileProject registered in Workspace, holds direct refs to Profile + Project. References Workspace via `_workspace` | Own state beyond what workspace provides; do I/O |
| `project.lua` | Project class, config_cache_key computation, mutation methods (save_options, save_type_config_field, save_variable, save_launch_config, etc.). References Workspace via `_workspace` | Own state beyond what workspace provides |
| `config_unit.lua` | Per-(project, config) runtime state: running action, progress, elapsed time, deleting flag (with reason: "deleting"/"cleaning"), queued action. Synced during remerge (`_update()` refreshes variant/tool from cache, preserves runtime state) + lazy creation via `get_config_unit()`. Listener pattern via `on_state_change()`. Owns `materialize()`, `materialize_pinned()`, `resolve_tool()`, `referencing_profiles()`. References Workspace via `_workspace` | Persist anything (runtime only) |
| `device.lua` | Device domain object: physical/emulated deployment target with serial, display_name, provider (module id), state (online/offline), properties. Runtime-only (not persisted). Workspace-level registry, discovered via module's `list_devices()` | Persist anything (runtime only) |
| `launch_target.lua` | LaunchTarget class: resolves profile's default target descriptor into object references (Project, ConfigUnit, Target). Three target types: module targets, command launches, device targets. `build()` builds deps → pre-build deploy → build self. `deploy()` executes post-build deploy steps. Both phases merge project-level + launch-level deploy. `launch()`/`debug()` for local targets. `device_install()`/`device_launch()` for device targets. `requires_device()` returns true for device targets | Own state beyond resolution; do I/O directly |
| `debug.lua` | DAP integration gateway. `run(spec, callbacks)` constructs DAP launch config with adapter-specific `extra` fields and calls `dap.run()`. Checks adapter availability before launch (Mason install hint). `resolve_adapter(workspace, module_type)` reads `user.json` debug settings with defaults (cmake→codelldb, typescript→pwa-node). `known_adapters(module_type)` returns picker options. Per-session callbacks via unique listener keys | Own state; depend on workspace internals |
| `session_tracker.lua` | Unified launch/debug lifecycle manager. Tracks active run (overseer task or dap session). `start(target, mode)` handles confirmation dialog, build→deploy→execute chain with device extension (device-install→device-launch for device targets), fidget progress. `stop()` terminates overseer task or dap session (with `hierarchy=true` to kill debuggee). Auto-cleans tracked run on dap session end via listeners. Device-log stream uses `-P pid` only (volume cap by app PID); level filtering is client-side on the ring buffer, so `:LoomworksDeviceLogLevel` retunes the live view without restarting hilog | Own state beyond what init.lua provides |
| `target.lua` | Target class: wraps module-detected build target (type, dependencies, artifact). `build()` delegates to module. `launch()` runs executable via overseer. Runtime-only, recreated on parse | Persist anything |
| `deploy.lua` | Deploy step validation, resolution, freshness checking, execution, cleanup. Pure functions — no state. Resolves source config units within profile context, compares mtime + source identity for freshness, copies files. `partition_by_phase()` splits a deploy dict by `pre_build` flag. `merge_deploy_sources()` merges project-level and launch-level deploy (directory destinations union, file destinations override) | Own state; do I/O beyond file copy |
| `variables.lua` | Project variable validation and resolution. `resolve(project, configuration)` walks inheritance chain via object references, returns values with provenance (source Configuration object). Reserved name checking | Own state; mutate anything |
| `operation.lua` | Operation class: tracks a user-initiated profile action. Watches ConfigUnit state changes to determine completion. Multiple Operations can coexist. Created by `Workspace:create_operation()`, cleaned up on completion via callback | Own state beyond what workspace provides; persist anything |
| `workspace_view.lua` | View-model layer: orchestration logic for UI. Computes add/remove project context, tool detection caching, upgrade/downgrade previews, config set candidates. Config set create/edit/rename/delete context and execution. Orphan cleanup: stray build dir detection (top-down prune of `.nvim/build/`), orphaned config collection, bulk cleanup execution. Calls Workspace atomic mutations in sequence. No UI rendering — pure compute + execute | Render UI; own state; bypass Workspace methods |
| `cmake_kits.lua` | CMake tool detection (MSVC via vswhere, Ninja+MSVC combos). GCC/Clang detection delegates to `compilers.lua`. Both sync (`detect()`) and async (`detect_async()`) variants. In-memory caching of results | Do I/O beyond process spawning for detection |
| `compilers.lua` | Shared C/C++ compiler detection (gcc/clang via PATH probing, versioned binary names). Returns `{id, display, family, version, path, c_path, bin_dir, clangd_path}` per compiler so modules can pin `CC`/`CXX` and prepend runtime-DLL directories to `PATH`. Used by both `cmake_kits.lua` and `modules/meson.lua`. Process-lifetime cache; `clear_cache()` forces rescan | Know about any specific module |
| `device_log.lua` | Client-side device-log view: line parser (`MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: msg`), session prefilter (pid OR proc-contains-bundle, applied at receive), soft filter (level / regex / tag / pid, applied at render), ring buffer (5000 records), bottom-split scratch buffer with level-based extmark highlights. Singleton view, one stream at a time. Streaming task runs under `loomworks.overseer.run_streaming_task` (visible in overseer's task list, killable there) | Spawn subprocesses directly (overseer owns the process); persist filter state (in-memory only for v1) |

### Data / IO Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `io.lua` | Atomic file read/write (sync and async), JSON encode/decode, rm_rf (sync fallback), rm_rf_async (subprocess), directory creation, read_file_async/read_files_async (libuv callbacks) | Validate domain semantics; know about loomworks data model |
| `config.lua` | `loomworks.json` parsing, validation, project type extraction | Write files (config is read-only) |
| `user.lua` | `loomworks.user.json` parse/save/defaults | Validate beyond structural correctness |
| `cache.lua` | `loomworks.cache.json` parse/save/defaults, version checking | Business logic; auto-migration |
| `file_tracker.lua` | Watching three JSON files via `uv.fs_poll`, content-change deduplication | Domain logic; know about merge or profiles |
| `config_editor.lua` | **Legacy** — retained for backward compatibility but not used at runtime. Mutation methods (`add_project`, `remove_project`, `add_configuration_set`, etc.) have moved to Workspace. Only `create_workspace` remains as a standalone entry point (paralleled by `workspace.create_workspace_config`) | Domain logic; know about runtime model |
| `modules/init.lua` | Module registry, lazy loading, detection orchestration (`detect_all_types`, `scan_directory_async`) | Implement module logic |
| `modules/cmake.lua` | CMake module: detect, validate, info (preset + loomworks config separation), default_configurations, resolve_configurations (inheritance model), resolve_options/resolve_options_with_sources (option merge with source tracking), resolve_variant_source, tasks (CMAKE_BUILD_TYPE auto-set, user -D options), inspect, detect_tools/detect_tools_async, parse_targets (target discovery), get_options (cache variables), map_variant. Static `has_keyed_tools = true`, `has_options = true` | Know about profiles, UI, or overseer |
| `modules/harmony.lua` | Harmony/OpenHarmony module: detect (build-profile.json5), validate, info (product/module/target extraction from build-profile.json5 via Node.js JSON5 parsing), default_configurations (product × target × ABI cross product), resolve_build_dir (hvigor's external cmake build dir outside .nvim/build/), lsp_configs (emits clangd entry with SDK-bundled binary for native configs), tasks (ohpm install + hvigor sync + assembleHap), clean_tasks, inspect (staleness detection + build dir verification via native_work_dir.txt), detect_tools/detect_tools_async, kits_from_sdk, tool_label, map_variant. Device interface: `list_devices` (hdc list targets), `device_targets` (Run on device), `device_install` (hdc install), `device_launch` (hdc shell aa start), `device_log` (hdc hilog), `resolve_artifact` (HAP path), `resolve_launch_info` (bundle/ability from app.json5/module.json5). Static `has_keyed_tools = false`, `has_options = false`, `has_devices = true` | Anything beyond the module interface |
| `modules/meson.lua` | Meson module: detect (meson.build), validate, info (defaults Debug/Release/RelWithDebInfo mapping to buildtype), resolve_configurations (inheritance on top of defaults), tasks (meson setup + compile; auto-picks --reconfigure on re-setup; -D option args; optional --cross-file), clean_tasks (meson compile --clean), parse_targets/parse_targets_async (via `meson introspect --targets`), get_options (via `meson introspect --buildoptions`, grouped by section), lsp_configs (clangd entry with build_dir as compile_commands_dir), inspect (meson.build / meson.options / meson_options.txt staleness), detect_tools/detect_tools_async (meson on PATH, then pip-user Scripts dir via Python sysconfig probe; non-keyed), create_test_unit (MesonTestUnit), map_variant. Static `has_keyed_tools = false`, `has_options = true` | Anything beyond the module interface |
| `test_units/meson.lua` | MesonTestUnit: wraps `meson introspect --tests` for discovery, gtest framework probing via shared helper, direct-exe gtest XML runs for per-test results. Same runtime surface as CTestUnit | Know about the meson module internals |
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
| `ui/config_editor_dialog.lua` | Edit dialog for project configuration properties. Supports name, inherits (multi-base with reordering), options (unified view with inheritance sources), variables (override/clear with provenance), toolchain, generator. Abstract mixin detection | Own persistent state |
| `ui/launch_editor.lua` | Edit dialog for launch config properties: name, command, args, working_dir, env, deploy steps. Deploy entries open deploy_editor on enter | Own persistent state |
| `ui/deploy_editor.lua` | Edit dialog for a single deploy step. Segment-based destination path builder (variable picker + literal text). Source picker for project, configuration, target (from domain objects). Resolved path preview | Own persistent state |
| `ui/variable_editor.lua` | Edit dialog for a project variable declaration: name, type (string/path), default value | Own persistent state |
| `ui/helpers.lua` | Shared formatting: progress strings, elapsed time, config status resolution | Side effects; domain logic |
| `ui/sections/*.lua` | Pure render functions `(tree, ctx) → void`. Each section is a single function that calls tree methods | Call core directly; do I/O; hold state |

### Integrations

| File | Owns | Must NOT do |
|------|------|-------------|
| `overseer.lua` | Template provider registration, task collection from modules, task launching with readiness checks and build dir lock acquisition, auto-configure-before-build, profile-level operations | Import core.lua directly; own state beyond task generation |
| `lsp.lua` | LSP dispatch layer + plugin-style integration registry. On load, scans every runtime path for `integrations/lsp/*.lua` and requires each — integrations self-register via `register(server, M)`. Exposes generic `cmd(server, base)` / `root_dir(server, fallback)` factories, a `setup_servers(opts)` that installs enabled integrations via `vim.lsp.config` + `vim.lsp.enable`, buffer excludes (`default_excludes()` / `excluded(bufnr)` + `LspAttach` detach autocmd) applied uniformly across all managed integrations, and `get_status()` dispatching per-server status fields to integrations. No server-specific logic | Contain server-specific wiring (lives in `integrations/lsp/<server>.lua`) |
| `integrations/lsp/clangd.lua` | clangd-specific wiring: `build_config(user_cfg)` for zero-config setup, function-based cmd + root_dir (resolve per-buffer: SDK clangd inside workspace, user base cmd outside), auto-restart on workspace/active set changes, capability auto-detection for blink.cmp/cmp_nvim_lsp, binary_required enforcement | Reference specific modules; read `project.cmake` or other module-specific fields |
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
            → detect_tools_async(config, cache)        ← vim.system for vswhere/compilers
              → vim.schedule → store results → ws:remerge()
              → tool_state = "scanned", emit "tools_detected"
              → flush _tool_waiters
```

Workspace state: `uninitialized` → `initializing` → `initialized`
Tool state: `not_scanned` → `scanning` → `scanned`

The first remerge produces an ActiveSet with empty tools. Profile sections
render immediately. When tool detection completes, a second remerge fills in
detected tools and the UI refreshes via `active_set_changed`.

Materialization calls (`_materialize_from_data`, `materialize_configuration`,
`materialize_pinned`) that arrive during `scanning` are queued in
`_tool_waiters` and replayed when detection completes.

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

### UI v2 (preview, alongside v1)

`lua/loomworks/ui/v2/` ships a redesigned three-pane workbench (overview
+ inspector + activity strip) alongside the v1 status page. The two
coexist: v1 owns `<leader>ww`, v2 owns `<leader>wW`. v2 is opt-in
until it has been validated in real-world use.

The v2 architecture differs from v1 by adding a clean view-model
boundary:

1. **View model** (`ui/v2/view_model/`) is pure Lua — no `vim.api.*`
   UI calls, no Snacks. It builds a presentation tree from workspace
   state, owns selection / wire-form draft / activity-mode state,
   subscribes to core events, and routes dispatch (cursor moves, edits,
   adds, renames, deletes). Per-inspector-kind builders live under
   `inspector_kinds/`.

2. **View** (`ui/v2/view/`) is a thin renderer. It holds a reference
   to the view model, opens windows (tabpage or float), translates
   the presentation tree to buffer lines + extmarks, and forwards
   keys + cursor events to the view model. No business logic.

3. **Palette** (`ui/v2/palette.lua`) builds dynamic action entries
   from the workspace state and presents via `vim.ui.select` (Snacks
   intercepts when configured). Reachable from any buffer via
   `<leader>wp`.

The view model is testable headlessly without opening any nvim
windows; tests under `tests/ui_v2/view_model_spec.lua` exercise the
full edit / dispatch surface against real Workspace instances. Layout
behaviour (window opening, cursor, resize) has its own tests under
`tests/ui_v2/layout_spec.lua`.

Spec: [`spec/ui-v2.md`](spec/ui-v2.md).

---

## Object Model

Workspace wraps raw merged data into domain objects that hold a `_workspace`
reference back to the Workspace instance for live queries and registry access.
Domain objects access infrastructure deps via `_workspace._core._deps`.
See specification.md §1.6, §1.7 for behavioral rules.

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
an error.

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
5. ConfigUnits — resolves Project + Tool + Configuration
6. ProfileProjects — resolves Profile + Project + ConfigUnit references
7. BuildDirs — domain objects for physical build directories with state
8. BuildDirRefs — reverse index from BuildDir paths

**Module** (`module.lua`) wraps a stateless module function table (cmake.lua,
harmony.lua, typescript.lua) as a per-workspace domain object. Owns the Tool
registry for its module type. No `_workspace` back-reference — pure domain
object. Created during `_sync_modules()`. `Project._module` replaces
`project.type` string for module identity (type string kept for display).

**Tool** (`tool.lua`) represents a toolchain (ninja-gcc-12, msvc-17-2022).
Owned by `Module._tools` registry, keyed by `tool_key`.
`Tool._module` references the owning Module domain object.
Created from async detection results AND from cached tool_data at startup.
For non-keyed modules (harmony, typescript), a single default Tool with nil key
exists. ConfigUnit, Profile, and Project carry `_tool` references alongside
legacy `tool` ToolRef tables. Accessor: `unit:tool_object()`,
`profile:tool_object_for(module)`.

**Configuration** (`configuration.lua`) represents a build variant (Debug,
Release, Debug-asan). Owned by `Project._configurations` registry, created
from module.info() output + loomworks.json user overrides. Separates generic
fields (name, variant, inherits, options) from module-specific data
(`module_config`). Inheritance uses Configuration object references resolved
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
`_tool_data`) and carries direct references: `_project`, `_tool`,
`_configuration`, `_build_dir` (BuildDir object).

**BuildDir** (`build_dir.lua`) represents a physical build directory with cached
state (configured, built, failed). Separate from ConfigUnit (user intent).
ConfigUnit references a BuildDir via `_build_dir`. Orphaned BuildDirs have state
but no ConfigUnit pointing to them. Created during `sync_build_dirs()` from cache
entries; task completion handler creates new BuildDirs when needed. Workspace owns
`_build_dirs` array (all BuildDirs including orphaned). No raw cache data is
retained after deserialization — BuildDir objects are the source of truth.

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

## File Layout

```
loomworks.nvim/
├── CLAUDE.md                          Project context for AI
├── ARCHITECTURE.md                    This file
├── specification.md                   Core behavioral specification
├── spec/
│   ├── ui.md                          Status page, highlights, winbar
│   ├── modules/                       Per-module specs (cmake, harmony, meson, typescript)
│   ├── integrations/lsp/              Per-LSP-server specs (clangd, …)
│   ├── integrations/debug/            Per-DAP-adapter specs (codelldb, cppdbg, pwa-node, …)
│   └── sdks/                          Per-SDK-provider specs (ohos, …)
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
│   │   ├── variables.lua             Project variable resolution + validation
│   │   ├── operation.lua              Operation class (profile action tracking)
│   │   ├── cmake_kits.lua             CMake tool detection (MSVC/VS; delegates gcc/clang)
│   │   ├── compilers.lua               Shared C/C++ compiler detection (used by cmake_kits + meson)
│   │   ├── device_log.lua              Client-side device-log view (parser, filter, ring buffer, bottom-split)
│   │   ├── types.lua                  LuaCATS type annotations (not loaded)
│   │   ├── overseer.lua               Overseer template provider + launching
│   │   ├── lsp.lua                    LSP registry + dispatcher (runtime-path discovery, setup_servers, get_status)
│   │   ├── integrations/
│   │   │   └── lsp/
│   │   │       └── clangd.lua         clangd integration (build_config, function-based cmd/root_dir, auto-restart)
│   │   ├── fidget.lua                 fidget.nvim progress integration
│   │   ├── config_editor.lua           Legacy JSON read-modify-write (not used at runtime)
│   │   ├── modules/
│   │   │   ├── init.lua               Module registry, detection orchestration
│   │   │   ├── cmake.lua              CMake module (full v1)
│   │   │   ├── harmony.lua              Harmony/OpenHarmony module (full)
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
│   │           ├── profiles.lua       Profiles section
│   │           ├── orphaned.lua       Orphaned Items section (configs + stray dirs)
│   │           ├── config_sets.lua    Configuration Sets section
│   │           ├── projects.lua       Projects section
│   │           └── debug.lua         Debug Adapters section
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
