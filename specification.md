# loomworks.nvim — Specification

This document is the authoritative behavioral specification for loomworks.nvim.
It defines *what* the system does — data model, state machines, UI behavior,
and invariants — not how it is implemented. The implementation (code) and
architecture (CLAUDE.md) must conform to this specification.

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
- Orphan adoption on startup (creates a pinned profile)

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
          │  ┌──│ building │
          │  │  └────┬─────┘
          │  │       │
          │  │ fail  │ success
          │  │       ▼
          │  │  ┌─────────┐
          │  │  │  built   │
          │  │  └─────────┘
          │  │
          ▼  ▼
   ┌──────────────────┐    ┌──────────────┐
   │ configure_failed │    │  build_failed │
   └──────────────────┘    └──────────────┘

   Any state ──── delete/clean ────► deleting ────► unconfigured (clean)
                                                    or removed (delete)
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

### 3.2 Cache state names vs ConfigUnit state names

| Cache state        | ConfigUnit state    |
|--------------------|---------------------|
| `unconfigured`     | `unconfigured`      |
| `configured`       | `configured`        |
| `built`            | `built`             |
| `failed_configure` | `configure_failed`  |
| `failed_build`     | `build_failed`      |
| (runtime only)     | `configuring`       |
| (runtime only)     | `building`          |
| (runtime only)     | `deleting`          |

---

## 4. Profile Lifecycle

### 4.1 Materialization

Materialization writes a profile to the cache so that build tasks can be
launched against it. A profile must be materialized before any task runs.

**Trigger**: `activate_profile()`, `build()`, `configure()`, `<CR>` in UI,
`p` key (pinned), or orphan adoption on startup.

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

### 4.5 Orphan Adoption

On startup, configs in cache that are not referenced by any profile are
"adopted":

- Configs with state (configured/built/failed) → pinned profile created
- Configs without state (unconfigured skeletons) → silently dropped

This ensures every meaningful cache entry is reachable through a profile.

### 4.6 Deletion

**Profile deletion** (`D` key):
1. Show confirmation dialog listing affected items
2. For each project in the profile:
   - If config is referenced by another profile → disposition = `keep`
   - If not → disposition = `clean` (remove cache entry + build dir)
3. Stop any running tasks for affected configs
4. Mark affected ConfigUnits as `deleting`
5. Execute deletions, remove profile from cache
6. Unmark ConfigUnits, flush deletion waiters, remerge

**Config deletion** (`D` key on a configuration):
1. Show confirmation dialog
2. If referenced by any profile (set-based or pinned) → disposition = `reset`
   (clear state but keep skeleton; profile stays and shows "unconfigured")
3. If not referenced by any profile → disposition = `clean` (remove entry)
4. Same stop/mark/execute/unmark cycle
5. No profiles are ever removed — profiles are only deleted via explicit
   profile deletion (`D` on the profile itself)

**Build directory deletion**: Build directories stored in the cache may reside
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
   - Delete build directory
   - Reset cache entry to unconfigured (clear state, build_dir, timestamps,
     cmake data)
   - Keep skeleton (variant, tool_key, tool_data)
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
| configure | any other          | skip     |
| build     | building           | skip     |
| build     | configuring        | defer    |
| build     | any other          | launch   |

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

Profile actions (build/configure) are tracked as "operations" for progress
reporting:

1. `start_operation(profile_key, action)` — records start time
2. Tasks run (potentially multiple projects in parallel)
3. `finish_operation(profile_key, success)` — computes duration message
   (e.g., "built in 1m23s", "configure failed in 42s")

The operation message is displayed in the Profiles section after the profile
name.

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

---

## 6. UI — Status Page

### 6.1 Layout

The status page opens as a vertical split (60 columns wide) and contains
three sections in order:

1. **Header** — plugin version, workspace name, workspace root
2. **Profiles** — all materialized and explicit profiles
3. **Configuration Sets** — declared sets with tool entries
4. **Projects** — all projects with their configurations

Sections are separated by blank lines. Each section has a title line.

### 6.2 Tree Structure

The status page uses a foldable tree widget with two-level nesting.

**Node types**:
- `leaf` — plain text line, no interaction
- `node` — foldable line with children, toggle via `<Tab>`
- `item` — interactive line with actions, no folding
- `group` — labeled sub-section that increases indentation
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

### 6.4 Profiles Section

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

### 6.5 Configuration Sets Section

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

### 6.6 Projects Section

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
```

**Configuration display** (non-keyed modules):
```
{fold_char} {config_name} {brief}
  {fold_char} Status: {status} {progress}
    Build dir: ...
    ...
```

**Configuration actions** (at the tool/status level):

| Action | Behavior |
|--------|----------|
| `b`    | Build this project+config (creates pinned profile if needed) |
| `c`    | Configure this project+config (creates pinned profile if needed) |
| `R`    | Clean + build |
| `C`    | Clean (reset to unconfigured) |
| `D`    | Delete config with dialog |
| `p`    | Pin as pinned profile |

### 6.7 Deletion Confirmation Dialog

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

### 6.8 Nuke Confirmation Dialog

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

### 6.9 Help Dialog

Floating window showing all keybindings. Destructive keys (`R`, `C`, `D`,
`<C-n>`) have their key character highlighted with `DiagnosticWarn`.

### 6.10 Auto-refresh

The status page refreshes automatically on these events:
- `task_started`, `task_stopped`, `task_result`, `task_progress`
- `deletion_started`, `deletion_completed`
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
| `deletion_completed`   | `DeletionItem[]` | Deletion operation ends |

Events pass data directly to listeners — no need to re-query, no race
conditions.

---

## 9. LSP Integration

### 9.1 clangd cmd factory

`loomworks.lsp.clangd_cmd(base_cmd)` returns a function suitable for
lspconfig's `cmd` option. It resolves per-project:

1. **clangd binary**: project-level override (`cmake.clangd` in
   loomworks.json) > kit auto-detected clangd_path > default from base_cmd
2. **compile_commands_dir**: `--compile-commands-dir=<build_dir>` injected
   based on active configuration's build directory. If
   `compile_commands_from` is set, uses that configuration's build dir
   instead.

### 9.2 clangd root_dir factory

`loomworks.lsp.clangd_root_dir(fallback?)` returns a function for
lspconfig's `root_dir`. For cmake projects, returns the project's absolute
path (so clangd scopes to the right project). Falls back to provided
function for non-cmake or when loomworks has no data.

### 9.3 Automatic restarts

The LSP module restarts clangd clients when:
- Workspace is first loaded
- Active set changes AND the compile_commands_dir or clangd binary has
  changed for any cmake project

Restarts are per-client and include notification of the reason.

---

## 10. Winbar / Statusline Component

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

## 11. Overseer Integration

### 11.1 Task generation

Modules provide task definitions via their `tasks()` function. Each task
definition includes:
- `builder()` — returns an overseer task specification
- `name` — display name
- `loomworks` — metadata: project_key, action, configuration_key, build_dir,
  tool_data, cmake info

### 11.2 Task tracking component

`loomworks.task_tracker` is an overseer component injected into every
loomworks-spawned task. It:

1. Registers the task on the appropriate ConfigUnit
2. Parses output for progress (module-specific parser)
3. On completion: records the task result to cache, unregisters from
   ConfigUnit

### 11.3 Task lifecycle

```
collect tasks → check readiness → launch/skip/defer → track → complete → record result
```

All tasks wait for pending deletions before starting.

---

## 12. Neovim Commands

| Command | Args | Description |
|---------|------|-------------|
| `:LoomworksInit [path]` | Optional directory | Initialize workspace (default: cwd) |
| `:LoomworksInfo` | None | Open/focus status page |

---

## 13. Invariants

1. **Cache is truth**: The cache reflects what exists on disk. It is never
   contradicted or overridden by config or user files.

2. **No auto-clean**: Failed states, orphaned entries, and stale profiles are
   never automatically removed. Only explicit user action modifies or removes
   cache entries.

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
