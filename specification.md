# loomworks.nvim — Specification

This document is the authoritative behavioral specification for loomworks.nvim.
It defines *what* the system does — data model, state machines, UI behavior,
and invariants — not how it is implemented. The implementation (code) and
architecture (ARCHITECTURE.md) must conform to this specification.

---

## 1. Data Model

### 1.1 Workspace

A workspace is a directory containing a `loomworks.json` file. It is the
top-level organizational unit.

- One workspace is active at a time.
- The workspace root is the directory containing `loomworks.json`.
- Opening files outside the workspace does not change the active workspace.
- The workspace name defaults to the root directory name; may be overridden
  via `"name"` in `loomworks.json`.

### 1.2 Project

A project is a sub-component of a workspace with a type (cmake, ets,
typescript, etc.). Projects are declared in `loomworks.json` under `"projects"`.

- Key: the project identifier (typically the directory name).
- `path`: relative to workspace root, defaults to the key.
- `type`: determined by the inner key (`"cmake": {}` means type = cmake).
- A project may be **orphaned**: present in cache but absent from the current
  `loomworks.json`. Orphaned projects are shown at the end of the Projects
  section with an "(orphaned)" label.

### 1.3 Configuration

A configuration is a named build variant within a project (e.g., Debug,
Release, ohos-debug). Configurations are discovered from:

1. CMakePresets.json (each configure preset becomes a configuration)
2. Module's `info()` function
3. Overrides in `loomworks.json` under `projects.<name>.<type>.configurations`

### 1.4 Configuration Set

A configuration set is a cross-project mapping declared in `loomworks.json`
under `"configuration_sets"`. It binds one configuration per project.

```json
"configuration_sets": {
  "Debug":   { "App": "Debug",   "Frontend": "development" },
  "Release": { "App": "Release", "Frontend": "production"  }
}
```

- Set names are used as-is (case-sensitive keys).
- Future auto-generation will produce capitalized names.
- A configuration set only defines *what's available*; it must be materialized
  into a profile before it can be built.

### 1.5 Tool

A tool is a module-specific toolchain selection. For cmake projects this means
a generator + compiler combination. Each module declares whether it has
"keyed tools" — tools that produce distinct build artifacts requiring separate
cache entries.

- **Keyed tools** (cmake): cache key = `"variant:tool_key"` (e.g.,
  `"Debug:ninja-gcc-12"`). Each generator+compiler produces different build
  output.
- **Non-keyed tools** (ets, typescript): cache key = `"variant"`. The tool
  does not affect the cache key.

Tool detection runs:
- When browsing available tools in the UI
- On `rescan_tools()` / `L` key in the status page
- NOT on every startup — startup reads tools from the cache

### 1.6 Profile

A profile is a fully resolved buildable unit. Every profile stores its own
**mappings** (project_key → variant) directly. Profiles are what users
activate, build, configure, and delete.

There is one Profile class. Profiles differ in two optional properties:

- **`configuration_set`**: if non-nil, the profile is "set-based" — its
  mappings are re-derived from the configuration set on every remerge, so
  adding/removing projects in `loomworks.json` automatically updates the
  profile. If nil, the profile is "pinned" — its mappings are stored
  directly and never re-derived.
- **`explicit`**: if true, the profile is declared in `loomworks.json`
  under `"profiles"` and always appears in the UI, even before
  materialization.

**Profile key formats**:

| Variant    | Key format                        | configuration_set |
|------------|-----------------------------------|-------------------|
| Set-based  | `set_name:tool_key` or `set_name` | non-nil           |
| Pinned     | `project/config_key`              | nil               |
| Explicit   | User-defined key                  | non-nil (typically)|

Pinned keys use `/` as separator to avoid collision with set-based keys that
use `:`. The config_key already includes the tool_key for keyed modules (e.g.,
`"App/Debug:ninja-gcc"`), so the tool is visible in the key.

**Profile lifecycle**:

1. **Unmaterialized** — exists as a potential combination of set + tool.
   Shown in Configuration Sets section as a tool entry. No cache entry.
2. **Materialized** — written to cache with mappings and skeleton config
   entries. Shown in Profiles section.
3. **Active** — the user-selected profile. Stored in
   `loomworks.user.json` as `active_profile`. Determines which
   configurations the LSP, statusline, and `buf_status()` report.
4. **Orphaned (stale)** — the profile's configuration set was removed from
   `loomworks.json`. The profile remains functional (builds still work)
   but is marked `[stale]` in the UI. Mappings are derived from cached
   project data instead of the config set.

**Profile materialization**:

Materialization happens when:
- User presses `<CR>` on a tool entry in Configuration Sets (activate)
- User presses `b` or `c` on a tool entry (build/configure)
- `materialize_profile()` API is called
- User presses `p` on a configuration (creates a pinned profile)

On materialization:
1. Profile definition is resolved (from config sets + detected tools, or
   from a direct project+config reference for pinned profiles)
2. Mappings are computed and stored on the profile
3. For each project in the mappings, a skeleton cache entry is created
4. Profile entry is written to `cache.profiles`
5. Cache is saved; merge is triggered

### 1.7 ConfigUnit

A ConfigUnit represents a unique (project_key, config_key) pair. It is the
**single source of truth** for that configuration's runtime state. Multiple
profiles may reference the same ConfigUnit; state changes are visible to all.

ConfigUnits are created lazily (flyweight pattern) and shared across the
entire system. They are never destroyed during a session.

### 1.8 loomworks.json Schema

```json
{
  "name": "MyWorkspace",
  "projects": {
    "App": {
      "path": "packages/app",
      "cmake": {
        "configurations": {
          "Debug": {},
          "Release": {},
          "ohos-debug": {
            "toolchain": "${OHOS_NDK_HOME}/cmake/ohos.toolchain.cmake"
          }
        },
        "compile_commands_from": "ninja-debug",
        "clangd": "${OHOS_NDK_HOME}/llvm/bin/clangd"
      }
    },
    "Frontend": { "typescript": {} },
    "NativeDemo": { "ets": {} }
  },
  "configuration_sets": {
    "Debug":   { "App": "Debug",   "Frontend": "development", "NativeDemo": "debug" },
    "Release": { "App": "Release", "Frontend": "production",  "NativeDemo": "release" }
  },
  "profiles": {
    "cross-ohos": {
      "configuration_set": "Debug",
      "kit_id": "ninja-ohos-clang"
    }
  }
}
```

**Top-level fields**:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Workspace display name (defaults to root dir name) |
| `projects` | Yes | Dict of project_key → project definition |
| `configuration_sets` | No | Dict of set_name → { project_key → variant } |
| `profiles` | No | Dict of profile_key → explicit profile definition |

**Project definition fields**:

| Field | Description |
|-------|-------------|
| `path` | Relative path from workspace root (defaults to project key) |
| `depends_on` | Reserved for future cross-project dependencies (ignored in v1) |
| `<type>` | Inner key determines project type; value is the type-specific config |

The type key (`cmake`, `ets`, `typescript`) is the only required field. Its
value is a table passed to the module as `type_config`.

**CMake type_config fields**:

| Field | Description |
|-------|-------------|
| `configurations` | Dict of config_name → config overrides |
| `compile_commands_from` | Name of another configuration to source compile_commands.json from |
| `clangd` | Path to project-specific clangd binary (`${ENV_VAR}` expanded) |

Configuration overrides may include:
- `toolchain`: path to CMake toolchain file (`${ENV_VAR}` expanded, no absolute paths)
- `role`: `"compile_commands"` hides the configuration from UI

**Explicit profile fields**:

| Field | Description |
|-------|-------------|
| `configuration_set` | Name of a configuration set to derive mappings from |
| `kit_id` | Tool key to use (e.g., `"ninja-ohos-clang"`) |

---

## 2. Three-File Model

### 2.1 loomworks.json — Intent

Declarative. Describes what projects exist and how they are structured.

- Committed or gitignored (user's choice).
- Changes are detected via file watcher and hot-reloaded.
- Paths are relative to workspace root.
- Absolute paths are **forbidden** (breaks portability).
- `${ENV_VAR}` expansion for toolchain paths.

### 2.2 .nvim/loomworks.user.json — User Preferences

Small, stable. Written only on explicit user action.

```json
{
  "_meta": { "version": 1 },
  "active_profile": "Debug:ninja-gcc-12"
}
```

- Always gitignored.
- Contains: active profile selection.
- Future: named toolchain definitions, default task.

### 2.3 .nvim/loomworks.cache.json — Reality

Sparse record of what has actually been configured and built.

```json
{
  "_meta": { "version": 3, "cached_at": "..." },
  "profiles": {
    "Debug:ninja-gcc-12": {
      "configuration_set": "Debug",
      "mappings": { "App": "Debug", "Frontend": "development" },
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "tool_label": "Ninja + GCC 12.3",
      "tool_mod_type": "cmake",
      "projects": {
        "App": { "config_key": "Debug:ninja-gcc-12" }
      }
    },
    "App/Debug:ninja-gcc-12": {
      "mappings": { "App": "Debug" },
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "tool_label": "Ninja + GCC 12.3",
      "tool_mod_type": "cmake",
      "projects": {
        "App": { "config_key": "Debug:ninja-gcc-12" }
      }
    }
  },
  "projects": {
    "App": {
      "type": "cmake",
      "path": "App",
      "configurations": {
        "Debug:ninja-gcc-12": {
          "state": "built",
          "build_dir": "/workspace/.nvim/build/App/Debug",
          "last_configured": "2026-03-10T12:00:00Z",
          "last_built": "2026-03-10T12:05:00Z",
          "variant": "Debug",
          "tool_key": "ninja-gcc-12",
          "tool_data": { ... },
          "cmake": { "generator": "Ninja", "compiler": "GCC 12.3" }
        }
      }
    }
  }
}
```

- Always gitignored.
- Never auto-removes entries — survives git branch switches intact.
- Grows as builds happen; shrinks only on explicit delete/clean.
- Self-describing: each configuration stores its tool properties.
- Atomic writes (temp + fsync + rename) with .bak recovery.

### 2.4 Three-file reconciliation

The merge operation produces the active set by reconciling all three files:

| In config | In cache | Result |
|-----------|----------|--------|
| Yes       | Yes      | Normal — show cached state |
| Yes       | No       | Available — unconfigured |
| No        | Yes      | Orphaned — shown distinctly, user cleans manually |

### 2.5 Environment variable resolution for toolchain paths

`loomworks.json` uses `${ENV_VAR}` references for toolchain paths (e.g.,
`"toolchain": "${OHOS_NDK_HOME}/cmake/ohos.toolchain.cmake"`). These
references are never stored resolved in `loomworks.json` — that file stays
portable. The cache stores the resolved absolute path alongside other tool
properties.

**Where each form lives**:

| File | Stores | Example |
|------|--------|---------|
| `loomworks.json` | Variable reference | `${OHOS_NDK_HOME}/cmake/ohos.toolchain.cmake` |
| `cache.json` | Resolved absolute path | `/opt/ohos-sdk/10/cmake/ohos.toolchain.cmake` |

**Resolution timing**: Environment variables are resolved at **task launch
time** (configure/build), not at startup or UI render. When the user presses
`c` or `b`, the system resolves `${ENV_VAR}` from the current environment.
If the variable is unset, the task is rejected immediately with an error
notification — no task is launched.

**Cache is descriptive, not prescriptive**: The resolved path stored in the
cache records what was used at the last configure. It is never used to drive
future builds — fresh resolution from `loomworks.json` + current environment
always takes precedence. This means:

- A profile with a built config remains fully **buildable** even when the
  env var is unset — cmake bakes the toolchain into `CMakeCache.txt` at
  configure time, so builds do not need re-resolution.
- A profile can only be **re-configured** when the env var is set.

**Staleness detection via `inspect()`**: The module's `inspect()` function
can compare the cached resolved path to the currently-resolved path. If they
differ (user updated SDK), `needs_refresh = true` with a reason like
"toolchain path changed." If the env var is unset, `inspect()` may add an
informational note but should NOT set `needs_refresh` since existing builds
still work.

**What is explicitly avoided**:
- No env var resolution on startup (unnecessary, potentially noisy)
- No toolchain/SDK existence validation at UI render time (expensive,
  module-specific — the right place for that check is task launch)
- No builds driven by cached paths (cache is a record, not a driver)

---

## 3. State Machine

### 3.1 ConfigUnit States

```
                ┌──────────────┐
                │ unconfigured │◄──── clean / initial
                └──────┬───────┘
                       │ configure started
                       ▼
                ┌─────────────┐
          ┌─────│ configuring │
          │     └──────┬──────┘
          │            │
    fail  │    success │
          │            ▼
          │     ┌────────────┐
          │     │ configured │◄──── successful configure
          │     └─────┬──────┘      (does not downgrade from built)
          │           │ build started
          │           ▼
          │     ┌──────────┐
          │     │ building │──────┐
          │     └────┬─────┘      │
          │          │            │ fail
          │  success │            │
          │          ▼            ▼
          │     ┌─────────┐  ┌────────────────┐
          │     │  built  │  │  build_failed  │
          │     └─────────┘  └────────────────┘
          ▼
   ┌──────────────────┐
   │ configure_failed │
   └──────────────────┘

   Any state ──── delete/clean ────► deleting ────► unconfigured (clean, success)
                                                    or removed (delete, success)
                                                    or unknown (failure)

   unknown ──── delete/clean ────► deleting ────► (same outcomes)
```

**State derivation priority**: `deleting > running > cached`

- If `_deleting` flag is set → `"deleting"`
- If `_action` is set → `"configuring"` or `"building"`
- Otherwise → read from `cached.state` (with name mapping)

**State transition rules**:

1. Successful configure does NOT downgrade from `built` to `configured`.
2. Failed states are never auto-cleaned (rebuilding large C++ is expensive).
3. Only explicit user action (clean/delete) removes failed state.
4. `last_configured` and `last_built` are stored separately — a failed build
   does not invalidate the configure timestamp.
5. The `deleting` state is transient — it exists only while a deletion
   operation is in flight.
6. The `unknown` state means the build directory may be partially deleted
   (e.g., subprocess was killed, or files were locked on Windows). The only
   user actions available from `unknown` are delete and clean (retry).
   Build and configure are blocked.

### 3.2 Cache state names vs ConfigUnit state names

| Cache state        | ConfigUnit state    |
|--------------------|---------------------|
| `unconfigured`     | `unconfigured`      |
| `configured`       | `configured`        |
| `built`            | `built`             |
| `failed_configure` | `configure_failed`  |
| `failed_build`     | `build_failed`      |
| `unknown`          | `unknown`           |
| (runtime only)     | `configuring`       |
| (runtime only)     | `building`          |
| (runtime only)     | `deleting`          |

---

## 4. Profile Lifecycle

### 4.1 Materialization

Materialization writes a profile to the cache so that build tasks can be
launched against it. A profile must be materialized before any task runs.

**Trigger**: `activate_profile()`, `build()`, `configure()`, `<CR>` in UI,
or `p` key (pinned).

**Process (set-based profiles)**:
1. Parse profile key → (set_name, tool_key)
2. Look up set_name in `configuration_sets` → mappings
3. Resolve tool_data from detected tools or cache
4. For each project in the mappings:
   - Compute config_key (variant + tool_key for keyed modules)
   - Create skeleton cache entry if absent
5. Write profile entry (with `configuration_set` and `mappings`) to
   `cache.profiles`
6. Save cache, trigger remerge

**Process (pinned profiles)**:
1. Receive project_key and config_key directly
2. Compute mappings = `{ [project_key] = variant }` (variant parsed from
   config_key)
3. Create skeleton cache entry if absent
4. Write profile entry (with `configuration_set = nil` and `mappings`) to
   `cache.profiles`
5. Save cache, trigger remerge

**Idempotent**: no-op if profile already exists in cache.

### 4.2 Activation

Activation makes a profile the "active" profile. The active profile determines:
- Which configurations are shown in `buf_status()`
- Which tool/config the LSP integration uses
- Which profile is highlighted with `LoomworksActive` in the status page

**Process**:
1. If profile doesn't exist in cache → materialize first
2. Write `active_profile` to `loomworks.user.json`
3. Trigger remerge (fires `active_set_changed` event)

### 4.3 Set Name Migration

When configuration set names change in `loomworks.json` (e.g., "debug" →
"Debug"), the system performs case-insensitive migration:

1. Build a lowercase lookup of config set names from the new config
2. For each cached profile with a non-nil `configuration_set`, if it doesn't
   match any config set exactly but does match case-insensitively:
   - Rename the profile key in cache
   - Update `configuration_set` in the profile
   - Update `active_profile` in user.json if it pointed to the old key
3. Save cache

Pinned profiles (`configuration_set == nil`) are skipped — they have no set
to migrate. This runs on both initial setup and config hot-reload.

### 4.4 Orphaned Profiles (Stale)

When a configuration set is removed from `loomworks.json`:

1. The profile's `configuration_set` no longer matches any config set
2. `resolve_profile_mappings()` falls back to `_cached_projects` data
3. Profile is marked with `orphaned_set = true`
4. Profile remains fully functional — builds still work using cached mappings
5. UI shows `[stale]` tag and a warning about the removed set

### 4.5 Orphaned Configurations

A cached configuration is **orphaned** when it has build state
(configured/built/failed) but is not referenced by any profile's `projects`
entries. Common cause: switching git branches where a profile was built on
one branch but the configuration set that produced it no longer exists.

**On startup**:
- Cached configs with state but no profile reference → kept as orphans
  (shown in the Orphaned Configurations UI section)
- Cached configs without state (unconfigured skeletons) and no profile
  reference → silently dropped from cache

**Rules**:
1. Orphaned configs are never auto-deleted — the user must explicitly delete
2. Orphaned configs are never auto-adopted into pinned profiles
3. The only action available on an orphaned config is delete (removes cache
   entry + build directory)
4. Orphaned configs do not affect profile resolution or the active set

### 4.6 Deletion

**Profile deletion** (`D` key):
1. Show confirmation dialog listing affected items
2. For each project in the profile:
   - If config is referenced by another profile → disposition = `keep`
   - If not → disposition = `clean` (remove cache entry + build dir)
3. Stop any running tasks for affected configs
4. Mark affected ConfigUnits as `deleting`
5. Remove profile entry from cache immediately (profile disappears from UI)
6. **Crash-safe cache update**: set cache state to `"unknown"` for all
   affected items and save cache to disk. This ensures that if Neovim
   crashes mid-deletion, the cache still tracks the build directories.
7. **Delete build directories asynchronously** via subprocess. Multiple
   directories are deleted in parallel (one subprocess per directory).
8. On success: remove/reset cache entries per disposition, save cache,
   flush deletion waiters, remerge
9. On failure: cache already has `"unknown"` state — notify user with
   subprocess error output, unmark ConfigUnits, remerge
10. On crash: cache has `"unknown"` entries on next startup, user can
    retry delete/clean

**Invariant**: every build directory on disk always has a corresponding
cache entry. Cache entries are only removed **after** the build directory
has been successfully deleted.

**Config deletion** (`D` key on a configuration):
1. Show confirmation dialog
2. If referenced by any profile (set-based or pinned) → disposition = `reset`
   (clear state but keep skeleton; profile stays and shows "unconfigured")
3. If not referenced by any profile → disposition = `clean` (remove entry)
4. Same async stop/mark/execute/unmark cycle
5. No profiles are ever removed — profiles are only deleted via explicit
   profile deletion (`D` on the profile itself)

**Async build directory deletion**: Build directories are deleted via
`vim.system()` subprocess calls (`rm -rf` on Unix, `cmd /c rd /s /q` on
Windows). This prevents blocking Neovim's event loop during deletion of
large build directories. Subprocess stderr is captured and shown to the
user on failure.

**Build directory safety**: Build directories stored in the cache may reside
anywhere under the workspace root (e.g., `<root>/build/`, `<root>/.nvim/build/`,
a preset's `binaryDir`). Before deleting a build directory, the system
normalizes the path and verifies it is under the workspace root. Paths that
resolve outside the workspace (e.g., via `../` traversal, absolute paths
pointing elsewhere, or corrupted cache entries) are refused with an error
notification and left untouched. This check lives in core (at the
`execute_deletion` / clean level), not in the io layer — the io layer is a
general-purpose utility that deletes what it is told to.

### 4.7 Cleaning

**Profile clean** (`C` key):
1. For each project in the profile:
   - Set cache state to `"unknown"` and save to disk (crash-safe)
   - Delete build directory asynchronously (same subprocess approach as
     deletion)
   - On success: reset cache entry to unconfigured (clear state, build_dir,
     timestamps, cmake data), keep skeleton (variant, tool_key, tool_data)
   - On failure: cache already has `"unknown"` state, notify user
2. Profile itself is NOT removed — it stays in the Profiles section

**Config clean** (`C` key on a configuration):
- Same as profile clean but for a single configuration

---

## 5. Task Execution

### 5.1 Task Readiness

Before launching a task, the system checks the ConfigUnit state:

| Action    | State              | Decision |
|-----------|--------------------|----------|
| configure | unconfigured       | launch   |
| configure | configure_failed   | launch   |
| configure | unknown            | block    |
| configure | any other          | skip     |
| build     | building           | skip     |
| build     | configuring        | defer    |
| build     | unknown            | block    |
| build     | any other          | launch   |

**Blocked tasks**: When a task is blocked due to `unknown` state, the user is
notified that the config must be cleaned or deleted first.

**Deferred tasks**: When a build task is deferred because its config is still
configuring, a listener is registered on the ConfigUnit. When configuring
finishes:
- If configure succeeded → launch the build task
- If configure failed → report failure, do not build

### 5.2 Auto-configure before build

When building a profile and some projects are unconfigured or in
`configure_failed` state:

1. Filter configure tasks to only those that need configuring
2. Launch configure tasks
3. On completion: if all succeeded → launch build tasks; if any failed →
   abort build

### 5.3 Profile-level operations

Profile actions (build/configure/delete/clean) are tracked as "operations"
for progress reporting:

1. `start_operation(profile_key, action)` — records start time
2. Tasks run (potentially multiple projects in parallel)
3. `finish_operation(profile_key, success)` — computes duration message
   (e.g., "built in 1m23s", "configure failed in 42s")

The operation message is displayed in the Profiles section after the profile
name.

Deletion and clean operations use separate `deletion_started`,
`deletion_completed`, and `deletion_failed` events (not operation tracking).
Fidget shows a spinner with a message like "Deleting Debug:ninja-gcc-12"
(no percentage — just a spinner). The status page shows the standard
spinner animation for deleting configs.

### 5.4 Progress tracking

- Each ConfigUnit tracks progress from a module-specific progress parser
  (e.g., ninja's `[n/m]` output)
- Profile-level progress is aggregated across all ProfileProjects:
  - Configure phase counts as 10% of total work
  - Build phase counts as 90% of total work
  - Percentage is averaged across all running projects
- Progress is displayed as `[n/m]` per-config and `N%` per-profile

### 5.5 Deletion waiter pattern

If a build/configure action is requested while a deletion is in progress:

1. `has_pending_deletions()` returns true
2. Action is deferred via `after_deletions(fn)`
3. When all deletions complete, deferred actions are flushed in order

### 5.6 Queued actions on deleting configs

If a build or configure action is requested on a ConfigUnit that is currently
in the `deleting` state:

1. The action is stored as a **queued action** on the ConfigUnit
   (`_queued_action`).
2. Only one action can be queued per ConfigUnit. If a new action is queued,
   it replaces the previous one.
3. Queueing a build/configure on a config mid-deletion **preserves the cache
   entry** — even if the original disposition was `clean` (full removal), the
   cache entry is kept and the deletion effectively becomes a clean+rebuild.
4. When deletion completes successfully:
   - If a queued action exists: reset cache entry to `unconfigured`, then
     execute the queued action
   - If no queued action: proceed with normal disposal (remove or reset per
     original disposition)
5. When deletion fails (`unknown` state):
   - Queued action is discarded — the user must retry the delete first
6. Queueing a delete or clean on a config that is already deleting is
   prevented (cannot stack deletions).

### 5.7 Task readiness: unknown state

Configs in `unknown` state block build and configure actions. The user must
issue a delete or clean first to resolve the unknown state. The UI should
indicate this restriction.

---

## 6. UI — Status Page

### 6.1 Layout

The status page opens as a vertical split (60 columns wide) and contains
these sections in order:

1. **Header** — plugin version, workspace name, workspace root
2. **Profiles** — all materialized and explicit profiles
3. **Orphaned Configurations** — unreferenced cached configs (hidden when empty)
4. **Configuration Sets** — declared sets with tool entries
5. **Projects** — all projects with their configurations

Sections are separated by blank lines. Each section has a title line.

### 6.2 Tree Structure

The status page uses a foldable tree widget with two-level nesting.

**Node types**:
- `leaf` — plain text line, no interaction. Accepts either `(text, hl)` or
  a list of `{text, hl}` chunks for mixed highlights on one line.
- `node` — foldable line with children, toggle via `<Tab>`
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

### 6.3 Keybindings

| Key     | Action      | Behavior |
|---------|-------------|----------|
| `<Tab>` | toggle_fold | Toggle fold on the current node |
| `<CR>`  | enter       | Activate profile (on profile/tool nodes) |
| `b`     | build       | Build (walks up to nearest node with `on_build`) |
| `c`     | configure   | Configure (walks up to nearest node with `on_configure`) |
| `p`     | pin         | Pin configuration as pinned profile |
| `R`     | rebuild     | Clean + build (destructive) |
| `C`     | clean       | Reset to unconfigured, delete build dir (destructive) |
| `D`     | delete      | Delete profile or configuration (destructive, with confirmation) |
| `L`     | load        | Load workspace from cwd / rescan tools |
| `<C-n>` | nuke        | Reset workspace: delete `.nvim/build/` + cache, reload (destructive, with confirmation) |
| `?`     | help        | Show help dialog |
| `q`     | (close)     | Close the status page |

**Action dispatch**: For `build`, `configure`, `rebuild`, `clean`, `delete`,
and `pin`, the tree walks upward from the cursor line to find the nearest
node that has the corresponding `on_<action>` callback. This means pressing
`b` on a child detail line triggers the build action of the parent node.

**Destructive action highlighting**: `R`, `C`, `D`, `<C-n>` keys are
highlighted with `DiagnosticWarn` in the help dialog.

### 6.4 Action Hints

Action hints show available keys close to the actionable items. Hints use
`Comment` highlight. Format: `[key] label  [key] label  ...` — keys in
brackets, separated by double spaces.

**Header hint**: After the Root line, a `Comment` leaf shows global actions:
`[?] help  [L] load  [<C-n>] reset`

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
| Configurations: | Projects | `[b] build  [c] configure  [p] pin  [R] rebuild  [C] clean  [D] delete` |

### 6.5 Profiles Section

Shows all materialized (cached) and explicit profiles. Profiles only appear
here when they exist in the cache or are declared in `loomworks.json`.

**Profile node display** (all profiles use the same rendering):
```
{marker} {fold_char} {profile_key} [{tag}] ({status_label}) [{elapsed}] [— {op_message}]
```

Where:
- `{tag}` = `[stale]` for orphaned profiles, `[explicit]` for declared
  profiles, omitted otherwise
- `{status_label}` = aggregate status from `Profile:status()` (e.g., "built",
  "1 configuring, 1 failed build", "3 configured, 2 unconfigured")
- `{elapsed}` = shown only when running (e.g., "1m23s")
- `{op_message}` = last operation result (e.g., "built in 42s")

All profiles — whether set-based or pinned — are displayed identically.
A pinned profile with key `"App/Debug:ninja-gcc"` appears like any other
profile; it simply has fewer projects when expanded.

**Profile highlight rules**:
| Condition | Highlight |
|-----------|-----------|
| Running + active | `LoomworksActive` |
| Running + not active | `LoomworksRunning` |
| Active (not running) | `LoomworksActive` |
| Failed status | `LoomworksFailed` |
| Unconfigured | `LoomworksUnconfigured` |
| Otherwise | `LoomworksConfigured` |

**Profile children** (when unfolded):
- Set name (with warning if orphaned/stale) — only for set-based profiles
- Tool label (with generator/compiler details)
- Last operation message
- Projects sub-group:
  - Each project: `project_key → variant {progress}` with status highlight
  - When unfolded: status, build dir, timestamps, cmake details

**Profile actions**:

| Node type | `<CR>` | `b` | `c` | `R` | `C` | `D` |
|-----------|--------|-----|-----|-----|-----|-----|
| Profile | activate | build all | configure all | clean+build all | clean all | delete with dialog |
| Project under profile | — | build config | configure config | clean+build config | clean config | delete config with dialog |

### 6.6 Orphaned Configurations Section

Shows cached configurations with build state that are not referenced by any
profile. Hidden when there are no orphaned configs (the common case).

**Title**: `Orphaned Configurations` with `Title` highlight.

**Layout**: Configs are grouped by project key (sorted alphabetically).
Each project is a foldable node; each config within is a foldable node
showing the config key and its status.

```
Orphaned Configurations

  ▶ App
    ▶ Debug:ninja-gcc-12 (built)
      Status: built
      Build dir: .nvim/build/App/Debug

  ▶ SubLib
    ▶ Release:msvc-2022 (configured)
      Status: configured
      Build dir: .nvim/build/SubLib/Release
```

**Highlight**: Project nodes use `LoomworksUnconfigured`. Config nodes use
`resolve_config_status()` highlights (same as Projects section).

**Actions**: Only `D` (delete) is mapped on config nodes. All other action
keys (`b`, `c`, `R`, `C`, `p`) are not bound — orphaned configs cannot be
built, configured, or pinned. Deletion shows the standard confirmation
dialog.

### 6.7 Configuration Sets Section

Shows declared configuration sets from `loomworks.json`. Only appears when
sets are declared.

**Set node display**:
```
{fold_char} {set_name}
```

Highlighted with `LoomworksActive` if the active profile belongs to this set,
otherwise `LoomworksActionable`.

**Set children** (when unfolded):
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

### 6.8 Projects Section

Shows all projects from the active set, including orphaned projects. Projects
are sorted alphabetically with orphaned projects at the end.

**Project node display**:
```
{fold_char} {project_key} [{type}] {orphan_tag} {refresh_tag}
```

Where:
- `{orphan_tag}` = "(orphaned)" if in cache but not in config
- `{refresh_tag}` = "!" if `needs_refresh` is true

**Project children** (when unfolded):
- Path
- Refresh reasons (if any, with `!` prefix and `DiagnosticWarn` highlight)
- Configurations sub-group

**Configuration display** (keyed-tool modules like cmake):
Each configuration shows its available tools:
```
{fold_char} {config_name} {brief}
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
{fold_char} {config_name} {brief}
  {fold_char} Status: {status} {progress}
    Build dir: ...
    ...
```

**Targets sub-tree** (cmake projects, post-configure only):

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
| `b`    | Build this project+config (creates pinned profile if needed) |
| `c`    | Configure this project+config (creates pinned profile if needed) |
| `R`    | Clean + build |
| `C`    | Clean (reset to unconfigured) |
| `D`    | Delete config with dialog |
| `p`    | Pin as pinned profile |

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

### 6.9 Deletion Confirmation Dialog

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

### 6.10 Nuke Confirmation Dialog

Shown when `<C-n>` is pressed. Floating window centered in editor.

**Content**:
1. Title: "Reset workspace cache"
2. List of paths that will be deleted:
   - `<root>/.nvim/build/`
   - `<root>/.nvim/loomworks.cache.json`
3. Confirmation prompt

**Root resolution**: Uses `ws.root` if a workspace is loaded, otherwise
resolves from cwd via `workspace.resolve_root()`.

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

**Safety checks** (in `nuke_cache(root)`):
1. Root must be an absolute path (rejects relative paths)
2. `loomworks.json` must exist at the root (confirms it is a real workspace)
3. Every path to delete is verified to be under `root/.nvim/` using
   normalized path prefix checking (prevents directory traversal)

If any check fails, the operation aborts with an error notification and
no files are deleted. These checks are specific to the nuke operation —
the general io layer does not restrict deletion paths, because normal
config/profile deletion may delete build directories anywhere.

### 6.11 Help Dialog

Floating window showing all keybindings. Destructive keys (`R`, `C`, `D`,
`<C-n>`) have their key character highlighted with `DiagnosticWarn`.

### 6.12 Auto-refresh

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

## 7. Highlight Groups

| Group                  | Default link     | Usage |
|------------------------|------------------|-------|
| `LoomworksActive`     | `DiagnosticOk`   | Active profile, active set |
| `LoomworksBuilt`      | `DiagnosticOk`   | Built configurations |
| `LoomworksConfigured` | `DiagnosticInfo`  | Configured (not yet built) |
| `LoomworksUnconfigured` | `Comment`      | Never configured |
| `LoomworksFailed`     | `DiagnosticError` | Failed configure or build |
| `LoomworksRunning`    | `DiagnosticWarn`  | Running tasks (non-active) |
| `LoomworksDeleting`   | `DiagnosticError` | Deletion in progress |
| `LoomworksUnknown`    | `DiagnosticWarn`  | Unknown state (partial deletion) |
| `LoomworksActionable` | `Normal`          | Actionable items (sets, configs) |

Users can override these by defining the highlight groups before plugin load.

---

## 8. Events

Events are the primary mechanism for cross-component communication.

| Event                  | Data | Trigger |
|------------------------|------|---------|
| `workspace_changed`    | `Workspace` | Workspace loaded |
| `active_set_changed`   | `ActiveSet` | Profile activated, remerge |
| `operation_started`    | `{ profile_key, action }` | Profile-level action begins |
| `operation_finished`   | `{ profile_key, success, message }` | Profile-level action ends |
| `task_result`          | `TaskResult` | Individual task completes |
| `task_started`         | (via ConfigUnit) | Task registered on a unit |
| `task_stopped`         | (via ConfigUnit) | Task unregistered |
| `task_progress`        | (via ConfigUnit) | Progress update |
| `deletion_started`     | `DeletionItem[]` | Deletion operation begins |
| `deletion_completed`   | `DeletionItem[]` | Deletion operation ends (success) |
| `deletion_failed`      | `{ items, errors }` | One or more build dir deletions failed |

Events pass data directly to listeners — no need to re-query, no race
conditions.

---

## 9. Module Interface

A module is a handler for a project type. Modules implement a standard
interface that the core system calls for project discovery, task generation,
and staleness detection.

### 9.1 Required methods

**`validate(path, config) → { valid, warnings[] }`**

Check whether the project directory is valid for this module type. `path` is
the absolute project directory. `config` is the type_config from
`loomworks.json` (the value of the `"cmake": {}` key).

- Return `{ valid = false, warnings = {...} }` to reject
- Return `{ valid = true, warnings = {...} }` with non-fatal warnings

**`info(path, config) → { configurations }`**

Return what the module knows about the project from its own files. Called
during merge to discover available configurations.

- `configurations`: dict of config_name → config info (generator, binary_dir,
  toolchain_locked, toolchain)

**`tasks(project, active_config) → task_def[]`**

Return overseer task definitions for a project in a given configuration.
`project` is a `ModuleContext` table with: `name`, `path`, `workspace_root`,
`configurations`, `tool_data`, `configuration_key`, `env`.

Each task_def has:
- `name`: display name
- `builder()`: returns an overseer task specification (`{ cmd, cwd, env }`)
- `loomworks`: metadata — `project_key`, `action` ("configure"|"build"),
  `configuration_key`, `build_dir`, optional `tool_data` and `cmake` info

**`inspect(path, config, cached) → { needs_refresh, reasons[], notes[] }`**

Compare current project files against cached state. Called when the config
hash has changed (fast pre-filter). `cached` is the dict of config_key →
cached config data for this project.

- `needs_refresh = true` + `reasons[]` for significant changes
- `notes[]` for informational observations
- Return `{ needs_refresh = false }` when no meaningful change detected

**`detect_tools() → tool_entry[]`**

Return available tools for this module type. Each entry has:
- `tool_data`: opaque table of tool properties (stored in cache)
- Additional fields added by core: `tool_key`, `tool_label`

Non-keyed modules (ets, typescript) return a single entry with empty
`tool_data`.

### 9.2 Tool identity methods

These methods define how tools are compared and displayed:

**`tool_key(tool_data) → string|nil`**

Return the cache key suffix for a tool. `nil` means no suffix (non-keyed
module — tool does not affect cache key).

**`tool_label(tool_data) → string|nil`**

Return a human-readable label for the tool. `nil` means omit from display
(single-tool module).

**`tools_match(a, b) → boolean`**

Return true if two tool_data tables represent the same tool. Used to match
detected tools against cached tools.

### 9.3 Optional methods

**`progress_parser(project?, active_config?) → string|nil`**

Return the name of a registered progress parser (e.g., `"ninja"`), or `nil`
if the module has no progress tracking. Parameters are optional — modules
may ignore them or use them to select a parser based on context.

**`parse_file_api(build_dir, config_name?) → targets?`** *(optional)*

Parse module-specific post-configure data from the build directory. Returns
a dict of `target_name → { type, dependencies? }` for project-owned targets,
or `nil` if no data is available. Called by core after a successful configure
task. `config_name` is provided for multi-config generators to select the
correct configuration from the reply.

Only project-owned build targets are included (executables and libraries).
Imported, alias, and utility targets are excluded. Dependencies list only
project-owned targets that this target links against.

### 9.4 CMakePresets integration (cmake module)

The cmake module reads `CMakePresets.json` + `CMakeUserPresets.json` with
full preset inheritance:

- Each non-hidden configure preset becomes a loomworks configuration
- Preset's `binaryDir` is used as the build directory (wins over defaults)
- Preset's `toolchainFile` / `CMAKE_TOOLCHAIN_FILE` maps to
  `toolchain_locked = true`
- Debug/Release/RelWithDebInfo are auto-generated **only if no presets exist
  and no configurations are declared in loomworks.json**
- Overrides in `loomworks.json` `configurations` block add to or override
  preset-derived configurations

### 9.5 CMake File API integration (cmake module)

The cmake module uses CMake's file-based API (codemodel v2) to discover
build targets after configure.

**Query setup**: The query file
`<build_dir>/.cmake/api/v1/query/codemodel-v2` is created before the
configure task runs (in the task builder). The file is an empty marker —
its presence tells CMake to write reply data on every configure.

**Reply parsing**: After a successful configure, core calls
`parse_file_api(build_dir, config_name?)` on the module. The cmake module
reads the codemodel reply from `<build_dir>/.cmake/api/v1/reply/`,
extracts project-owned targets, and returns them.

**Target filtering**: Only project-owned build targets are included:
- Executables (`EXECUTABLE`)
- Static libraries (`STATIC_LIBRARY`)
- Shared libraries (`SHARED_LIBRARY`)
- Module libraries (`MODULE_LIBRARY`)
- Object libraries (`OBJECT_LIBRARY`)
- Interface libraries (`INTERFACE_LIBRARY`)

Imported targets, alias targets, and utility targets (e.g., `install`,
`uninstall`) are excluded.

**Dependencies**: Link dependencies between project-owned targets are
recorded. Dependencies on imported or external targets are excluded.

**Storage**: Targets are stored in
`cache.projects[key].configurations[config_key].cmake.targets`. The
entire targets dict is replaced on every successful configure (not
merged).

---

## 10. LSP Integration

### 10.1 clangd cmd factory

`loomworks.lsp.clangd_cmd(base_cmd)` returns a function suitable for
lspconfig's `cmd` option. It resolves per-project:

1. **clangd binary**: project-level override (`cmake.clangd` in
   loomworks.json) > kit auto-detected clangd_path > default from base_cmd
2. **compile_commands_dir**: `--compile-commands-dir=<build_dir>` injected
   based on active configuration's build directory. If
   `compile_commands_from` is set, uses that configuration's build dir
   instead.

### 10.2 clangd root_dir factory

`loomworks.lsp.clangd_root_dir(fallback?)` returns a function for
lspconfig's `root_dir`. For cmake projects, returns the project's absolute
path (so clangd scopes to the right project). Falls back to provided
function for non-cmake or when loomworks has no data.

### 10.3 Automatic restarts

The LSP module restarts clangd clients when:
- Workspace is first loaded
- Active set changes AND the compile_commands_dir or clangd binary has
  changed for any cmake project

Restarts are per-client and include notification of the reason.

---

## 11. Winbar / Statusline Component

`lualine/components/loomworks.lua` provides a lualine component for
winbar display.

**Default display**: `{set_name} {join} {project}/{configuration}`

Where `{join}` defaults to `\u{e0b1}` (powerline thin right arrow) with
spaces.

**Configurable via `show` option**: array of parts to display:
- `"set_name"` — configuration set name
- `"project"` — project key for current buffer
- `"configuration"` — active configuration
- `"tool_key"` — tool key (e.g., "ninja-gcc-12")

**Returns empty** when:
- No workspace loaded
- No active profile
- Current buffer is not in any project

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
| `"auto"` | Always load silently when `loomworks.json` is found in cwd. Notify via `vim.notify`. |
| `"cached_only"` | Load silently if cache exists (`.nvim/loomworks.cache.json`). For uncached workspaces, notify but do not load. |
| `"prompt"` | Load silently if cache exists. For uncached workspaces, prompt the user for confirmation. |
| `false` | Never auto-load. Only manual `:LoomworksInit`. |

### 13.2 Triggers

Auto-load runs on:
1. **Plugin load** — checks cwd for `loomworks.json`
2. **`DirChanged` event** — checks new cwd for `loomworks.json`
3. **`SessionLoadPost` event** — re-checks cwd after session restore
4. **`User ResessionLoadPost` event** — re-checks cwd after resession.nvim
   session restore (safe to register even if resession is not installed)

All checks use **cwd only** — no parent directory walking. Use
`:LoomworksInit` for workspaces in parent or non-cwd directories.

### 13.3 Behavior

When a trigger fires:
1. Check if `loomworks.json` exists in cwd (single `stat` call).
2. If not found → no-op.
3. If found and a workspace is already loaded at that root → no-op.
4. If found and a **different** workspace is already loaded → prompt
   "Switch workspace to {name}?" regardless of `auto_load` mode.
5. If found and no workspace is loaded:
   - `"auto"` → load and notify: "Loaded workspace: {name}"
   - `"cached_only"` + cache exists → load and notify
   - `"cached_only"` + no cache → notify: "Workspace found at {root}
     (run :LoomworksInit to load)"
   - `"prompt"` + cache exists → load and notify
   - `"prompt"` + no cache → prompt: "loomworks.json found at {root},
     load workspace? (y/n)"
   - `false` → no-op

### 13.4 Loading side effects

Loading a workspace (whether via auto-load or `:LoomworksInit`) always:
- Reads `loomworks.json`, `loomworks.cache.json`, `loomworks.user.json`
- Creates `.nvim/loomworks.cache.json` if it does not exist
- Emits `active_set_changed` event

### 13.5 Limitations

- **No file watching for `loomworks.json` creation**: If the file is created
  after Neovim starts and no `:cd` occurs, use `:LoomworksInit` manually.
- **No parent directory walking**: Auto-load only checks cwd, not parent
  directories. Opening Neovim in `workspace/src/` will not find
  `workspace/loomworks.json`. Use `:LoomworksInit` or `:cd` to the root.

## 14. Neovim Commands

| Command | Args | Description |
|---------|------|-------------|
| `:LoomworksInit [path]` | Optional directory | Initialize workspace (default: cwd) |
| `:LoomworksInfo` | None | Open/focus status page |

---

## 15. Invariants

1. **Cache is truth**: The cache reflects what exists on disk. It is never
   contradicted or overridden by config or user files.

2. **No auto-clean**: Failed states, orphaned configurations, and stale
   profiles are never automatically removed. Only explicit user action
   modifies or removes cache entries. Orphaned configurations (cached configs
   with state but no profile reference) are preserved and shown in the UI
   for the user to manage.

3. **Deletion safety**: All build directory deletions (config delete, clean,
   nuke) verify that the target path is under the workspace root before
   proceeding. Paths resolving outside the workspace are refused with an
   error notification. The nuke operation (`<C-n>`) is further restricted
   to `root/.nvim/` and requires that `loomworks.json` exists at the root.

4. **Atomic writes**: All file writes (cache, user) use temp + fsync + rename
   with .bak recovery on read failure.

5. **ConfigUnit is source of truth for runtime state**: Running, deleting,
   and progress state are never stored elsewhere. All queries go through
   ConfigUnit.

6. **Profile existence implies cache entry**: Every profile shown in the
   Profiles section has a corresponding entry in `cache.profiles`.

7. **Materialization before action**: No build/configure task runs without
   the profile being materialized to cache first.

8. **Event-driven UI refresh**: The status page never polls. All updates are
   triggered by events from the core system.

9. **Idempotent materialization**: Calling `materialize_profile()` on an
   already-materialized profile is a no-op.

10. **Generation counter**: Objects (Profile, Project) track staleness via a
    generation counter incremented on every remerge. Stale objects may have
    outdated data.

11. **Cache version check**: On load, the cache version (`_meta.version`) is
    checked against the expected version. If the version is incompatible,
    setup refuses to load — the workspace stays nil, the cache file on disk
    is untouched, and the user is notified. The status page shows the
    normal "No workspace loaded" state. The user can press `<C-n>` to nuke
    the cache and build artifacts, which deletes `.nvim/build/` and
    `loomworks.cache.json`, then re-runs setup. This is the only way to
    resolve a version mismatch — the system never silently discards or
    overwrites an incompatible cache.
