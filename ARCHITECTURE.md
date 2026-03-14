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
                         core.lua  ◄── stateful orchestrator (owns all state)
                             |
          +------------------+------------------+------------------+
          |                  |                  |                  |
    file_tracker.lua    workspace.lua      merge.lua         events.lua
    uv.fs_poll-based    pure assembly      three-file        on/off/emit
    watches 3 files     from raw strings   merge into        listener system
    delivers content                       ActiveSet
          |                  |
          |            +-----+-----+
          |            |     |     |
          v         config  user  cache
      io.lua        .lua   .lua   .lua
      read_file     parse  parse  parse
      write_atomic  valid  save   save
      rm_rf         load   load   load
          |
    ======|================================================
          |           Disk (workspace root)
          |
      loomworks.json
      .nvim/loomworks.user.json
      .nvim/loomworks.cache.json
      .nvim/build/...

                         core.lua
                             |
          +------------------+------------------+
          |                  |                  |
    config_unit.lua    profile.lua         project.lua
    Runtime state      Profile +            Project
    per (proj,cfg)     ProfileProject       wrapper
    flyweight          objects              object
          |
          +-- progress/init.lua + ninja.lua
              Parser registry for build output

                         core.lua
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
   Persistent build state → cache.json. Intent → loomworks.json. User
   choices → user.json. If you find the same information stored in two
   places, eliminate one.

5. **Constructor injection for testability.** Core uses `Core.new(deps)`
   with a default dependency table that tests can selectively override.
   All external dependencies (I/O, vim APIs, time, scheduling) go through
   the deps table — never call `vim.fn`, `vim.uv`, or `os.date` directly
   from core.lua. This makes every behavior testable without mocking
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
   back into core or the data model. In disk formats (cache.json), use
   lightweight references (e.g., `{ "config_key": "Debug:ninja-gcc-12" }`)
   that point to the canonical data rather than duplicating it.

7. **Methods over free functions.** If a function takes an object as its
   first parameter and is clearly about that object, it should be a method
   on the object rather than a standalone function elsewhere. Example:
   `profile:status()` not `compute_profile_status(profile)`. This keeps
   related behavior co-located and discoverable.

8. **Pure where possible.** Functions that don't need state should not have
   state. merge.lua is pure (data in, data out). workspace.lua is pure.
   Modules are stateless — they receive paths and config, return results.
   Only core.lua is stateful, and it is the single owner of all mutable
   state.

---

## Layers and Dependency Rules

The codebase has five layers. Dependencies flow **downward only** — a layer
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
│  Core               core, merge, profile, project,  │
│                     config_unit, events, cmake_kits  │
├─────────────────────────────────────────────────────┤
│  Data / IO          config, user, cache, workspace, │
│                     io, file_tracker, modules/*,     │
│                     progress/*, types                │
└─────────────────────────────────────────────────────┘
```

**Key dependency rules:**

1. **init.lua** is a thin facade — it creates one `Core` instance and
   delegates every public function. No logic lives here.
2. **core.lua** is the only component that mutates shared state. Everything
   else either reads state (UI, integrations) or is pure (merge, workspace,
   parse layers).
3. **merge.lua** is a pure function — takes workspace data in, returns
   ActiveSet out. No side effects, no I/O, no state.
4. **UI sections** receive a `(tree, ctx)` pair and call tree methods to
   render. They never call io.lua, cache.lua, or core.lua directly — all
   data comes through `ctx` (assembled in status.lua) or `require("loomworks")`
   for API calls.
5. **Modules** (cmake, ets, typescript) know nothing about profiles, UI, or
   overseer. They implement the module interface (validate, info, tasks,
   inspect, detect_tools) and operate on project paths and config data.
6. **Integrations** (overseer, lsp, fidget, lualine) consume the public API
   via `require("loomworks")` and listen for events. They never import
   core.lua directly.
7. **config_unit.lua** is shared across layers — core creates and owns
   units, but UI and integrations read their state. Units are the single
   source of truth for runtime state (see specification.md §1.7, §3.1).

---

## Component Responsibilities

### Entry Points

| File | Owns | Must NOT do |
|------|------|-------------|
| `plugin/loomworks.lua` | Command registration (`:LoomworksInit`, `:LoomworksInfo`), double-load guard | Contain logic; import core.lua |
| `init.lua` | Singleton Core instance, public API surface, version string | Hold state beyond the Core ref; contain business logic |

### Core Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `core.lua` | All mutable state (`_workspace`, `_active_set`, `_config_units`, `_generation`, `_operations`, `_tools_by_type`, `_setup_error`). Setup, remerge, object factories, profile management, task lifecycle, deletion orchestration, buffer queries | Do I/O directly (delegates to io.lua); know about UI; render anything |
| `merge.lua` | Three-file merge algorithm, profile resolution, mapping computation, orphaned project detection | Mutate state; do I/O; depend on core.lua |
| `profile.lua` | Profile and ProfileProject classes, status aggregation, plan_deletion | Own state beyond what core provides; do I/O |
| `project.lua` | Project class, config_cache_key computation | Own state beyond what core provides |
| `config_unit.lua` | Per-(project, config) runtime state: running action, progress, elapsed time, deleting flag, queued action. Listener pattern via `on_state_change()` | Persist anything (runtime only); know about profiles |
| `events.lua` | Pub/sub system: `on()`, `off()`, `emit()` | Hold domain state; know about specific event semantics |
| `cmake_kits.lua` | CMake tool detection (MSVC via vswhere, GCC/Clang via PATH probing, Ninja+MSVC combos). In-memory caching of results | Do I/O beyond process spawning for detection |

### Data / IO Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `io.lua` | Atomic file read/write, JSON encode/decode, rm_rf (sync fallback), rm_rf_async (subprocess), directory creation | Validate domain semantics; know about loomworks data model |
| `config.lua` | `loomworks.json` parsing, validation, project type extraction | Write files (config is read-only) |
| `user.lua` | `loomworks.user.json` parse/save/defaults | Validate beyond structural correctness |
| `cache.lua` | `loomworks.cache.json` parse/save/defaults, version checking | Business logic; auto-migration |
| `workspace.lua` | Root resolution, file path derivation, workspace assembly from raw strings | I/O (pure functions only) |
| `file_tracker.lua` | Watching three JSON files via `uv.fs_poll`, content-change deduplication | Domain logic; know about merge or profiles |
| `modules/init.lua` | Module registry, lazy loading | Implement module logic |
| `modules/cmake.lua` | CMake module: validate, info (preset reading), tasks, inspect, detect_tools, parse_file_api (target discovery) | Know about profiles, UI, or overseer |
| `modules/ets.lua`, `modules/typescript.lua` | Shim modules (validate + info only) | Anything beyond the shim interface |
| `progress/init.lua` | Parser registry mapping tool names to parser functions | Parse output itself |
| `progress/ninja.lua` | Ninja `[n/m]` output parser | Know about other build tools |
| `types.lua` | LuaCATS type annotations for all data shapes | Contain runtime code (never `require`d) |

### UI Layer

| File | Owns | Must NOT do |
|------|------|-------------|
| `ui/status.lua` | Wiring: creates Tree + View, assembles `ctx` from API, requires sections in order | Contain rendering logic; do I/O |
| `ui/view.lua` | Window lifecycle (open/close/toggle), keymap registration, event-driven refresh, animation timer | Know about section content; contain domain logic |
| `ui/tree.lua` | Foldable tree widget: node/leaf/item/group/blank primitives, fold state, action dispatch (walk-up), buffer rendering | Know about loomworks domain; do I/O |
| `ui/actions.lua` | Action factories: capture context at render time, return closures for deferred execution. Deletion confirmation dialog | Render tree nodes; own state |
| `ui/helpers.lua` | Shared formatting: progress strings, elapsed time, config status resolution | Side effects; domain logic |
| `ui/sections/*.lua` | Pure render functions `(tree, ctx) → void`. Each section is a single function that calls tree methods | Call core directly; do I/O; hold state |

### Integrations

| File | Owns | Must NOT do |
|------|------|-------------|
| `overseer.lua` | Template provider registration, task collection from modules, task launching with readiness checks, auto-configure-before-build, profile-level operations | Import core.lua directly; own state beyond task generation |
| `lsp.lua` | clangd cmd factory, root_dir factory, auto-restart on active set change | Manage LSP clients directly (delegates to lspconfig) |
| `fidget.lua` | fidget.nvim progress handles for operations and tasks | Require fidget.nvim unconditionally (graceful no-op) |
| `task_tracker.lua` | Overseer component bridging task lifecycle to ConfigUnit and cache recording | Be imported by anything except overseer |
| `lualine/components/loomworks.lua` | Winbar component showing active profile context for current buffer | Import core.lua; do anything beyond formatting |

---

## Data Flow

### Startup

```
plugin/loomworks.lua
  → init.lua: setup({ root = path })
    → core.lua: setup()
      → io.read_json × 3 files
      → workspace.assemble(root, config, user, cache)
      → cache version check (refuse if incompatible)
      → config.validate()
      → _migrate_set_names()
      → _cleanup_orphaned_skeletons()
      → merge.merge() → ActiveSet
      → wrap objects (Profile, Project, ConfigUnit)
      → file_tracker.start() (watch for external changes)
      → events.emit("active_set_changed")
      → events.emit("workspace_changed")
```

### File Change (hot-reload)

```
file_tracker (uv.fs_poll, 2s interval)
  → stat change detected → read content → compare to last known
  → core._on_file_changed(which_file, new_content)
    → config changed → reassemble workspace + validate + remerge
    → user changed   → re-parse user data + remerge
    → cache changed  → re-parse cache data + remerge
  → remerge() → events.emit("active_set_changed")
  → UI/integrations react to event
```

### Task Execution

```
User action (b/c key or API call)
  → overseer.lua: collect tasks from module
  → check ConfigUnit readiness (skip/defer/launch)
  → wait for pending deletions if any
  → launch overseer task with task_tracker component injected
    → task_tracker.on_start → ConfigUnit:set_running()
    → task_tracker.on_output → progress parser → ConfigUnit:set_progress()
    → task_tracker.on_complete → core.record_task_result() → cache.save()
                               → ConfigUnit:clear_running()
                               → events.emit("task_result")
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

Core wraps raw merged data into objects that hold a reference back to Core
for live queries. See specification.md §1.6, §1.7 for behavioral rules.

```
Core (singleton via init.lua)
  ├── Profile[]           ← from merge, one per cached/explicit profile
  │     └── ProfileProject[]  ← one per project in profile's mappings
  ├── Project[]           ← from active set, one per project
  └── ConfigUnit{}        ← flyweight registry, one per (project, config) pair
```

All objects carry a `_generation` stamp from Core. When Core remerges,
`_generation` increments and `object:is_stale()` returns true for
previously-created objects.

**ConfigUnit** is the meeting point — Profile, Project, and task_tracker all
reference the same ConfigUnit for a given (project_key, config_key). State
changes on a ConfigUnit are immediately visible to all consumers.

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
├── specification.md                   Behavioral specification
├── README.md                          User-facing documentation
├── lua/
│   ├── loomworks/
│   │   ├── init.lua                   Public API facade
│   │   ├── core.lua                   Stateful orchestrator
│   │   ├── workspace.lua              Pure workspace assembly
│   │   ├── file_tracker.lua           uv.fs_poll file watcher
│   │   ├── io.lua                     Atomic file read/write
│   │   ├── config.lua                 loomworks.json parse/validate
│   │   ├── user.lua                   user.json read/write
│   │   ├── cache.lua                  cache.json read/write
│   │   ├── merge.lua                  Three-file merge → ActiveSet
│   │   ├── events.lua                 Event/signal system
│   │   ├── profile.lua                Profile + ProfileProject classes
│   │   ├── project.lua                Project class
│   │   ├── config_unit.lua            Per-config runtime state (flyweight)
│   │   ├── cmake_kits.lua             CMake tool detection
│   │   ├── types.lua                  LuaCATS type annotations (not loaded)
│   │   ├── overseer.lua               Overseer template provider + launching
│   │   ├── lsp.lua                    clangd factories + auto-restart
│   │   ├── fidget.lua                 fidget.nvim progress integration
│   │   ├── modules/
│   │   │   ├── init.lua               Module registry (lazy-load)
│   │   │   ├── cmake.lua              CMake module (full v1)
│   │   │   ├── ets.lua                ETS shim
│   │   │   └── typescript.lua         TypeScript shim
│   │   ├── progress/
│   │   │   ├── init.lua               Progress parser registry
│   │   │   └── ninja.lua              Ninja [n/m] output parser
│   │   └── ui/
│   │       ├── status.lua             Status page wiring
│   │       ├── view.lua               Window lifecycle + keymaps
│   │       ├── tree.lua               Foldable tree widget
│   │       ├── actions.lua            Action factories + delete dialog
│   │       ├── helpers.lua            Shared formatting
│   │       └── sections/
│   │           ├── profiles.lua       Profiles section
│   │           ├── orphaned.lua       Orphaned Configurations section
│   │           ├── config_sets.lua    Configuration Sets section
│   │           └── projects.lua       Projects section
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
