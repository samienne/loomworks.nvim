# loomworks.nvim Architecture

## Overview

loomworks.nvim is a Neovim workspace management plugin that reconciles three
JSON files (intent, preferences, reality) into a single merged view, then
exposes that view to consumers (LSP, overseer task runner, future DAP) via
typed objects and an event system.

The plugin is **assistive, not authoritative** — it reads project files
(CMakeLists.txt, CMakePresets.json, etc.) to understand the workspace but never
modifies them. All plugin state lives under `.nvim/` in the workspace root.

## System Diagram

```
                          plugin/loomworks.lua
                      :LoomworksInit  :LoomworksInfo
                                 |
                           init.lua
                     Public API facade (singleton)
                                 |
                             core.lua
                    Stateful orchestrator (owns all state)
                    _workspace, _active_set, _tracker,
                    _running_tasks, _deleting, _generation
                       |          |           |
          +------------+    +-----+-----+     +------------+
          |                 |           |                   |
    file_tracker.lua   workspace.lua  merge.lua       events.lua
    uv.fs_poll-based   Pure assembly  Three-file      on/off/emit
    watches 3 files    from raw       merge into      listener
    delivers content   strings        ActiveSet       system
          |                 |
          |            +---------+----------+
          |            |         |          |
          v         config.lua user.lua  cache.lua
      io.lua        parse()    parse()   parse()
      read_file     validate() default() default()
      write_atomic  load()     load()    load()
      read_json                save()    save()
      write_json
      rm_rf
          |
    ======|==============================================
          |           Disk (workspace root)
          |
      loomworks.json
      .nvim/loomworks.user.json
      .nvim/loomworks.cache.json
      .nvim/build/...
```

## Three-File Model

The core data model is a reconciliation of three JSON files:

| File | Role | Mutated by |
|---|---|---|
| `loomworks.json` | **Intent** — what projects exist, types, configuration sets | User (editor or git) |
| `.nvim/loomworks.user.json` | **Preferences** — active profile, per-user choices | Plugin (on explicit user action) |
| `.nvim/loomworks.cache.json` | **Reality** — what has actually been configured/built | Plugin (after task completion) |

The merge produces an `ActiveSet`: a fully resolved view of all projects with
their statuses, configurations, kits, and cached build state.

```
  loomworks.json ----+
                     |
  user.json ---------+--> workspace.assemble() --> Workspace
                     |                                |
  cache.json --------+                           merge.merge()
                                                      |
                                                  ActiveSet
                                                      |
                                              Core wraps into objects
                                                      |
                                      +---------------+---------------+
                                      |               |               |
                                   Profile        Project      ProfileProject
```

## Layer Responsibilities

### Entry Points

- **`plugin/loomworks.lua`** — Auto-loaded by Neovim. Creates `:LoomworksInit`
  and `:LoomworksInfo` commands. Guard variable prevents double-load.

- **`init.lua`** — Public API facade. Creates a singleton `Core` instance and
  delegates all calls. This is what consumers `require("loomworks")` to get.

### Core (`core.lua`)

The central orchestrator. Uses a constructor pattern (`Core.new(deps)`) for
testability with injectable dependencies. Owns all mutable state:

| Field | Purpose |
|---|---|
| `_workspace` | Assembled Workspace (config + user + cache) |
| `_active_set` | Merged ActiveSet (projects, profiles, kits) |
| `_tracker` | FileTracker instance watching the three files |
| `_running_tasks` | Map of overseer task_id -> running task info |
| `_deleting` | Set of project+config keys being deleted |
| `_generation` | Counter incremented on every remerge (staleness detection) |

Key responsibilities:
- Setup: read files, assemble workspace, validate, start tracking
- Remerge: re-run merge when any source file changes
- Object factories: create Profile/Project/ProfileProject wrappers
- Profile management: activate, deactivate, switch configuration sets
- Task lifecycle: register/unregister running tasks, record results to cache
- Deletion: plan, execute (stop tasks, remove build dirs, update cache)
- Buffer queries: find which project contains a given buffer

### Workspace Assembly (`workspace.lua`)

Pure functions with no state and no I/O:

- `resolve_root(path)` — normalize a directory path
- `paths(root)` — derive the three file paths from a workspace root
- `assemble(root, config_content, user_content, cache_content)` — build a
  Workspace struct from raw JSON strings

### File Tracking (`file_tracker.lua`)

Watches the three JSON files for external changes using `uv.fs_poll` (stat-based
polling at 2-second intervals). Uses `fs_poll` instead of `fs_event` because
atomic writes via rename change inodes, which breaks `fs_event` on Linux/macOS.

- Delivers raw string content via callback on change
- Compares content to last known value to prevent spurious callbacks
- Self-triggered writes (plugin saves cache, fs_poll fires) are handled
  idempotently — if content matches what Core already has, no action is taken

### Merge (`merge.lua`)

Combines all three files into the `ActiveSet`:

1. Auto-generates profiles from `configuration_sets x detected_kits`
2. Merges explicit profiles from config (override auto-generated)
3. Resolves active profile from user preferences
4. For each project: calls module `info()`, looks up cache state, runs `inspect()`
5. Detects orphaned projects (in cache but not in config)

### I/O (`io.lua`)

Synchronous file operations with safety features:

- **Atomic writes**: write to `.tmp`, fsync, rename existing to `.bak`, rename
  `.tmp` to target. Windows retry logic for lock contention.
- **JSON fallback**: `read_json()` tries the primary file first, falls back to
  `.bak` on decode failure.
- **Safe deletion**: `rm_rf()` for build directory cleanup.

### Parse Layer (`config.lua`, `user.lua`, `cache.lua`)

Each file module provides:
- `parse(content)` — decode JSON string, validate, return typed struct
- `load(root)` — read from disk + parse (convenience, used by legacy paths)
- `save(root, data)` — atomic write (user.lua, cache.lua only)
- `default()` — return empty/default struct

The `parse()` functions enable testing without disk I/O.

Config validation includes: project type extraction (implicit from inner key
like `{"cmake": {}}`), path existence checks, configuration_set reference
validation, and profile validation.

## Object Model

Core wraps raw merged data into objects that hold a reference back to Core for
live queries (running tasks, deletion state):

### Profile

Represents a **configuration_set x kit** combination. A workspace with 2
configuration sets and 3 kits produces 6 auto-generated profiles.

```
Profile
  .key                  "debug:ninja-gcc-14.2.0"
  .configuration_set    "debug"
  .kit_id               "ninja-gcc-14.2.0"
  .kit                  { generator = "Ninja", compiler_path = "..." }
  .mappings             { ProjectA = "Debug", ProjectB = "development" }

  :status()             Aggregate across all child projects
  :is_configured()      Any cached entries matching this profile?
  :is_running()         Any tasks currently running?
  :projects()           Returns ProfileProject[] sorted by key
  :project(key)         Returns single ProfileProject
  :plan_deletion()      Returns DeletionPlan with shared analysis
  :activate()           Set as active profile
  :delete(on_done)      Plan + execute deletion
```

### Project

Wraps merged project data from the active set. Represents a project as seen
through the currently active profile.

```
Project
  .key                  "ScenePluginAddon"
  .type                 "cmake"
  .configuration        "Debug"
  .configuration_key    "Debug:ninja-gcc-14.2.0"
  .status               "built"
  .configurations       { Debug = {...}, Release = {...} }
  .cached               { state = "built", last_built = "..." }

  :running_action()     "configure" | "build" | nil
  :cached_config(name)  Resolve cached state for any configuration
  :is_stale()           Has Core remerged since this object was created?
  :to_module_context()  Build the table passed to module.tasks()
```

### ProfileProject

A single project within a specific profile. Thin wrapper that precomputes the
cache key (variant + kit_id) for queries.

```
ProfileProject
  .project_key          "ScenePluginAddon"
  .variant              "Debug"
  .config_key           "Debug:ninja-gcc-14.2.0"

  :status()             Live status including "configuring"/"building"/"deleting"
  :cached_state()       Cached config data from cache.json
  :running_action()     Action currently running for this exact config
```

All three objects carry a `_generation` stamp. If Core has remerged since the
object was created, `is_stale()` returns true.

## Module System

Modules handle project-type-specific logic. They implement a standard interface:

```
modules/init.lua           Registry with lazy-loading
  |
  +-- modules/cmake.lua    Full v1 implementation
  +-- modules/ets.lua      Shim (validate + info only)
  +-- modules/typescript.lua  Shim (validate + info only)
```

### Module Interface

| Method | Purpose |
|---|---|
| `validate(path, config)` | Check project directory, return `{valid, warnings[]}` |
| `info(path, config)` | Return configurations, targets (from project files) |
| `tasks(project_ctx, active_config)` | Return overseer task templates |
| `inspect(path, config, cached)` | Compare current state to cache, detect staleness |

### CMake Module

The cmake module is the only full implementation in v1:

- Reads `CMakePresets.json` + `CMakeUserPresets.json` with full inheritance
- Falls back to `CMakeLists.txt` parsing for Debug/Release detection
- Generates configure + build tasks for overseer
- Handles multi-config generators (Visual Studio, Ninja Multi-Config) vs
  single-config (plain Ninja)
- Supports toolchain files, vcvarsall wrapping for MSVC+Ninja combos

## CMake Kit Detection (`cmake_kits.lua`)

Detects available build toolchains:

- **MSVC kits**: via `vswhere.exe`, creates Visual Studio generator entries
- **Ninja + compiler kits**: probes PATH for gcc/g++/clang/clang++ (versioned),
  creates Ninja generator entries per compiler
- **Ninja + MSVC kits**: combines Ninja generator with vcvarsall environment

Results are cached in memory. Each kit has: id, display name, generator,
compiler path, environment variables, optional vcvarsall path + architecture.

## Consumer Integration

### Overseer (`overseer.lua`)

Registers as an overseer template provider. Tasks are generated dynamically:

1. For each non-orphaned project with an active configuration
2. Call the module's `tasks()` to get task templates
3. Wrap each task's builder to inject the `loomworks.task_tracker` component
4. Return templates to overseer's picker

The task tracker component (`lua/overseer/component/loomworks/task_tracker.lua`)
bridges overseer task lifecycle to loomworks:
- `on_start` -> `register_running_task()`
- `on_complete` -> `unregister_running_task()` + `record_task_result()`
- `on_dispose` -> `unregister_running_task()` (cleanup)

Profile-level actions (`run_profile_action`) can configure+build all projects
in a profile, automatically configuring unconfigured projects before building.

### Status UI (`ui/status.lua`)

`:LoomworksInfo` opens a scratch buffer with two-level folding:

- Top level: profiles (configuration sets x kits)
- Second level: projects within each profile
- Shows build status icons, timestamps, per-target state
- Spinner animation for running tasks
- Actions: activate profile, delete cached configs
- Auto-refreshes on `active_set_changed` events

### Events (`events.lua`)

Simple pub/sub system. Core emits events, consumers subscribe:

| Event | Data | When |
|---|---|---|
| `workspace_changed` | Workspace | Initial load or full reassembly |
| `active_set_changed` | ActiveSet | Any remerge (profile switch, task complete, file change) |
| `task_started` | task info | Overseer task begins |
| `task_stopped` | task info | Overseer task ends |
| `task_result` | TaskResult | Task success/failure recorded to cache |
| `deletion_started` | items[] | Deletion begins |
| `deletion_completed` | items[] | Deletion finishes |

## State Machine

Build states per configuration key (variant + kit):

```
                          configure
  unconfigured ─────────────────────────> configured
       |                                      |
  configure fails                         build ok
       |                                      |
  failed_configure                          built
                                              |
                              build fails     |  config changes
                                  |           |       |
                             failed_build     |   needs_refresh
                                              |       |
                                              +<------+
                                              |
                                           rebuild
                                              |
                                            built
```

`needs_refresh` and `orphaned` are orthogonal flags, not states. The system
remains functional regardless of flag values — they are informational for UI.

## File Change Flow

```
  External edit to loomworks.json
       |
  file_tracker (uv.fs_poll, 2s interval)
       |  stat change detected
       |  read new content
       |  compare to last known
       |
  Core:_on_file_changed(path, content)
       |
       +-- config changed -> reassemble + validate + remerge
       +-- user changed   -> parse + replace user data + remerge
       +-- cache changed  -> parse + replace cache data + remerge
       |
  remerge() -> events.emit("active_set_changed")
       |
  UI/overseer react to event
```

Multi-instance safety: no lock files (Windows stale lock issues). When two
Neovim instances share a workspace, each re-reads on fs_poll and uses
last-writer-wins semantics. The design is idempotent — re-reading the same
content is a no-op, and re-reading changed content just updates to latest state.

## Deletion Flow

Deletion is async to handle running tasks gracefully:

1. `plan_deletion()` — analyze what to delete, detect shared configs across profiles
2. Mark items as "deleting" (prevents new tasks from starting)
3. Find and stop running overseer tasks for affected items
4. Wait for tasks to complete
5. Remove build directories (safety check: must be under `.nvim/build/`)
6. Remove cache entries
7. Save cache, remerge, emit events
8. Notify waiters (other operations waiting for deletion to finish)

## Dependency Injection

Core uses a `DEFAULT_DEPS` table that tests can override:

```lua
local core = Core.new({
  io = mock_io,
  modules = mock_modules,
  notify = function() end,
  schedule = function(fn) fn() end,
})
```

Key injectable dependencies: `workspace`, `merge`, `events`, `user`, `cache`,
`config`, `io`, `modules`, `FileTracker`, `notify`, `now`, `normalize`,
`schedule`, `get_overseer_task`, `buf_name`.

## File Layout

```
loomworks.nvim/
+-- CLAUDE.md                     Design context for AI assistants
+-- ARCHITECTURE.md               This file
+-- lua/
|   +-- loomworks/
|   |   +-- init.lua              Public API facade
|   |   +-- core.lua              Stateful orchestrator
|   |   +-- workspace.lua         Pure workspace assembly
|   |   +-- file_tracker.lua      uv.fs_poll file watcher
|   |   +-- io.lua                Atomic file read/write
|   |   +-- config.lua            loomworks.json parse/validate
|   |   +-- user.lua              user.json read/write
|   |   +-- cache.lua             cache.json read/write
|   |   +-- merge.lua             Three-file merge -> ActiveSet
|   |   +-- events.lua            Event/signal system
|   |   +-- profile.lua           Profile + ProfileProject objects
|   |   +-- project.lua           Project object
|   |   +-- cmake_kits.lua        CMake kit/compiler detection
|   |   +-- types.lua             LuaCATS type definitions (not loaded)
|   |   +-- overseer.lua          Overseer template provider
|   |   +-- modules/
|   |   |   +-- init.lua          Module registry
|   |   |   +-- cmake.lua         CMake module (full v1)
|   |   |   +-- ets.lua           ETS shim
|   |   |   +-- typescript.lua    TypeScript shim
|   |   +-- ui/
|   |       +-- status.lua        :LoomworksInfo status page
|   +-- overseer/
|       +-- component/
|           +-- loomworks/
|               +-- task_tracker.lua  Overseer component for task lifecycle
+-- plugin/
    +-- loomworks.lua             Auto-load entry point
```
