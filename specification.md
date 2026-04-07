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
typescript, etc.). Projects are declared in `loomworks.json` and/or
`loomworks.user.json` under `"projects"` (see §2.4 for the merge model).

- Key: the project identifier (typically the directory name).
- `path`: relative to workspace root, defaults to the key.
- `type`: determined by the inner key (`"cmake": {}` means type = cmake).
- A project may be **orphaned**: present in cache but absent from the current
  config (both loomworks.json and user.json). Orphaned projects are shown at
  the end of the Projects section with an "(orphaned)" label.

### 1.3 Configuration

Two kinds of configurations exist:

**Loomworks configurations** — managed by loomworks. Defaults auto-generated
by the module (cmake: Debug, Release, RelWithDebInfo, MinSizeRel). Users
can add custom configs with inheritance and options. Invoked via
`cmake -S ... -B ... -D...`. Editable from the status page.

**Preset configurations** — detected from CMakePresets.json at runtime.
Invoked via `cmake --preset <name>`. Read-only from loomworks' perspective.
Shown separately in the UI. Referenced in config set mappings with
`preset:` prefix (e.g., `"App": "preset:Debug"`).

Loomworks configuration fields in the workspace config:
```
<type>.options                              — project-wide -D flags
<type>.configurations.<name>.inherits       — base config(s), string or array
<type>.configurations.<name>.options        — per-config -D flags
<type>.configurations.<name>.toolchain      — path to .cmake toolchain file
<type>.configurations.<name>.generator      — override generator
```

**Inheritance model** (cmake): custom configs inherit from one or more bases.
Variant (CMAKE_BUILD_TYPE) is derived from the first base with a variant.
Options merge depth-first left-to-right: project-wide → bases → own
(later values override). Configs without a variant-providing base are
abstract mixins — not directly buildable, only usable as bases.

**Default configurations**: always present, auto-generated from
`CMAKE_CONFIGURATION_TYPES` in CMakeLists.txt or standard cmake defaults
(Debug, Release, RelWithDebInfo, MinSizeRel). User entries in
the workspace config extend defaults (add options) rather than replace them.

### 1.3.1 Project Variables

Projects can declare user-defined variables with typed defaults. These
variables are expanded alongside built-in variables in launch configs
(command, args, env, working_dir) and deploy destinations.

**Declaration** in the workspace config (project level):

```json
"App": {
    "typescript": {},
    "variables": {
        "output_dir": { "type": "path", "default": "${project_path}/dist" },
        "debug_port": { "type": "string", "default": "9229" }
    }
}
```

**Types**: `string` (arbitrary text) and `path` (filesystem path — enables
path-aware UI such as the segment editor). Types are declared at the
project level and cannot be changed by configurations.

**Configuration overrides**: Configurations can override variable values
but cannot add new variables or change types. Overrides follow the
configuration inheritance chain.

```json
"cmake": {
    "configurations": {
        "Debug": {
            "variables": { "output_dir": "${project_path}/dist/debug" }
        },
        "Release": {
            "variables": { "output_dir": "${project_path}/dist/release" }
        }
    }
}
```

**Resolution order** (first match wins, most specific first):
1. This configuration's override
2. Parent configuration overrides (inheritance order, depth-first left-to-right)
3. Project default

**Value expansion**: Variable values can reference built-in variables
(`${workspace_root}`, `${build_dir}`, `${variant}`, `${config_set}`,
`${project_path}`) but NOT other user-defined variables. This prevents
circular references and keeps resolution simple. Cross-variable references
are deferred to a future version (with loop detection).

**Reserved names**: User variables cannot use built-in variable names
(`workspace_root`, `build_dir`, `variant`, `config_set`, `project_path`).
The system rejects declarations with reserved names at parse time.

**Provenance tracking**: Each resolved variable value tracks its source —
which specific configuration provided the value, or whether it comes from
the project default. The editor displays this provenance so the user can
see where each value originates (e.g., "from Debug", "from project
default", "overridden here").

**user.json**: Variable declarations and overrides live in user.json as
part of the working copy (see §2.4). Published variables are written to
loomworks.json on `:w`.

**Design for extension** (not in v1):
- `${parent:var_name}` — reference the value from the parent scope
  (parent configuration or project default). Enables appending to
  inherited values (e.g., `${parent:flags} -DFOO`).
- `${project:var_name}` — reference the project default directly,
  skipping the inheritance chain.
- Cross-variable references with loop detection.
- Workspace-level variables (shared across projects).

### 1.4 Configuration Set

A configuration set is a cross-project mapping declared in the workspace
config under `"configuration_sets"`. It binds one configuration per project.

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

Tool detection runs asynchronously in the background:
- Automatically after workspace initialization completes
- On `rescan_tools()` / `L` key in the status page

Detection results are cached in memory for the session. Merge and
build operations work without detection results — cached profiles
store their own tool_data. Detection is only needed to populate the
tool entries list in the Configuration Sets UI and to materialize
new profiles.

Each module declares a static `has_keyed_tools` property (boolean)
so that config key construction works before detection completes.

### 1.6 Profile

A profile is a fully resolved buildable unit. Every profile stores its own
**mappings** (project_key → variant) directly. Profiles are what users
activate, build, configure, and delete.

There is one Profile class. Profiles differ in two optional properties:

- **`configuration_set`**: if non-nil, the profile is "set-based" — its
  mappings are re-derived from the configuration set on every remerge, so
  adding/removing projects in the config automatically updates the profile.
  If nil, the profile is "pinned" — its mappings are stored directly and
  never re-derived.
- **`explicit`**: if true, the profile is declared in the workspace config
  under `"profiles"` and always appears in the UI, even before
  materialization.

**Profile keys are opaque identifiers** — they exist solely for cache
persistence and display. They carry no semantic meaning and must never be
parsed, compared, or used to match profiles to other objects. All matching
uses object references or property-based comparison.

**Profile key formats** (write-time conventions, not runtime contracts):

| Variant    | Key format                        | configuration_set |
|------------|-----------------------------------|-------------------|
| Set-based  | `set_name:tool_key` or `set_name` | non-nil           |
| Pinned     | `project/config_key`              | nil               |
| Explicit   | User-defined key                  | non-nil (typically)|

Key collisions are resolved by appending `-2`, `-3`, etc. via
`cache.next_available_key()`.

**Profile lifecycle**:

1. **Unmaterialized** — exists as a potential combination of set + tool.
   Shown in Configuration Sets section as a tool entry. No cache entry.
2. **Materialized** — written to cache with mappings and skeleton config
   entries. Shown in Profiles section.
3. **Active** — the user-selected profile. Stored in
   `loomworks.user.json` as `active_profile` (see §2.2). Determines which
   configurations the LSP, statusline, and `buf_status()` report.
4. **Orphaned (stale)** — the profile's configuration set was removed from
   `loomworks.json`. The profile remains functional (builds still work)
   but is marked `[stale]` in the UI. Mappings are derived from cached
   project data instead of the config set.

**Profile materialization**:

Materialization happens when:
- User presses `<CR>` on a tool entry in Configuration Sets (activate)
- User presses `b` or `c` on a tool entry (build/configure)
- `ConfigurationSet:activate()` is called (materializes then activates)
- User presses `p` on a configuration (creates a pinned profile)

On materialization:
1. Structured data (set_name, tool_entry) is passed directly — no profile
   key parsing needed
2. Mappings are derived from the configuration set
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

### 2.1 loomworks.json — Published Snapshot

Shared configuration. Contains items the user has explicitly **published**.
Written only when the user saves from the status page (`:w`).

- Committed or gitignored (user's choice).
- Changes from outside (branch switch, manual edit) are detected via file
  watcher and hot-reloaded.
- Paths are relative to workspace root.
- Absolute paths are **forbidden** (breaks portability).
- `${ENV_VAR}` expansion for toolchain paths.
- The system functions without this file — user.json alone is sufficient.

### 2.2 .nvim/loomworks.user.json — Working Copy

The primary working file. All UI mutations land here. Contains the full
working state: every item the user has interacted with, plus metadata
(active profile, pinned profiles, published flags).

```json
{
  "_meta": { "version": 3 },
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "pinned_profiles": { ... },
  "default_target": { ... }
}
```

- Always gitignored.
- Written on every UI mutation (add/edit/remove project, config, profile, etc.).
- Items carry a `_published` flag indicating whether they should appear in
  loomworks.json on the next save.

### 2.4 Publish/Working-Copy Model

The two config files follow a **working-copy / published-snapshot** model:

- **user.json** is the live working state. All UI edits go here.
- **loomworks.json** is a published snapshot. Written only on explicit `:w`.

#### Published flag

Each publishable item has a `_published` boolean controlling whether it
should appear in loomworks.json:

- **Projects**: `_published` on the project declaration and individually on
  each configuration, launch config, and variable declaration within the
  project. A project can be partly published (some configs shared, others
  personal).
- **Configuration sets**: `_published` as a whole (atomic unit).
- **Profiles**: not publishable in v1. Profiles bind machine-specific tools
  and have a complex lifecycle (pinned vs explicit). Profile publishing is
  deferred until the profile model is simplified.

#### Modified indicator (`+`)

An item shows `+` when the next `:w` would change loomworks.json for that
item. This is computed by comparing the current state against a **shared
baseline** (the last-loaded/written loomworks.json content):

| Published | In shared | Matches | `+` | `:w` action |
|-----------|-----------|---------|-----|-------------|
| yes       | no        | —       | `+` | add to shared |
| yes       | yes       | yes     | —   | no-op |
| yes       | yes       | no      | `+` | update shared |
| no        | no        | —       | —   | no-op |
| no        | yes       | —       | `+` | remove from shared |

The `+` indicator **bubbles up**: if any child of a project is modified, the
project header also shows `+`.

#### Dimmed items

Items that exist only in loomworks.json (not yet in user.json) are displayed
with `Comment` highlight (dimmed). This includes:
- Shared-only projects/configs the user hasn't touched
- Module-generated default configurations (not in any file)

Dimmed items are usable but read-only from the UI. On first interaction
(edit, use in a profile), the item is auto-copied to user.json.

#### Per-configuration merge

Projects from loomworks.json and user.json are merged at the **configuration
level**, not the project level. If shared defines Debug and Release, and user
defines Debug (modified) and Debug-asan (new), the merged project has all
three: shared Release, user Debug, user Debug-asan. User wins per-key within:
- `type_config.configurations` — per config name
- `launch` — per launch config name
- `variables` — per variable name

Project-level fields (`path`, `type`, `depends_on`, module settings like
`compile_commands_from`) come from user.json if present, otherwise from
shared.

#### Saving (`:w`)

`:w` on the status buffer writes published items to loomworks.json:
- Published items with changes: written to loomworks.json
- Items marked for unpublish (published=false but in loomworks.json): removed
- Unpublished items: skipped
- After write: shared baseline is updated, `+` indicators clear

#### External changes

When loomworks.json changes on disk (branch switch, git pull, manual edit):
- The shared baseline is updated from the new file content.
- Dimmed items (shared-only, not in user.json): auto-update immediately.
- Items in user.json that were synced with the old baseline: auto-update
  to match the new shared content (stay synced).
- Items in user.json that diverge from old baseline: keep user version,
  `+` is recomputed against the new baseline.

#### Publish toggle (`P`)

The `P` key on the status page toggles the `_published` flag on the item
under the cursor. Toggling saves to user.json and refreshes the display.

### 2.3 .nvim/loomworks.cache.json — Reality

Sparse record of what has actually been configured and built.

```json
{
  "_meta": { "version": 6, "cached_at": "..." },
  "configurations": {
    "App/Debug:ninja-gcc-12": {
      "project_key": "App",
      "config_key": "Debug:ninja-gcc-12",
      "type": "cmake",
      "state": "built",
      "variant": "Debug",
      "build_dir": "/workspace/.nvim/build/App/Debug",
      "last_configured": "2026-03-10T12:00:00Z",
      "last_built": "2026-03-10T12:05:00Z",
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "cmake": { "generator": "Ninja", "compiler": "GCC 12.3" }
    }
  },
  "profiles": {
    "Debug:ninja-gcc-12": {
      "configuration_set": "Debug",
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "tool_label": "Ninja + GCC 12.3",
      "tool_mod_type": "cmake",
      "configurations": ["App/Debug:ninja-gcc-12"]
    }
  },
  "deploy_state": {
    "/workspace/App/Debug/native.node": {
      "source_build_dir": "build/NativeLib/Debug:ninja-gcc-12",
      "source_rel_path": "native_lib.node",
      "source_mtime": "2026-03-31T10:00:00Z"
    }
  }
}
```

- Always gitignored.
- Never auto-removes entries — survives git branch switches intact.
- Grows as builds happen; shrinks only on explicit delete/clean.
- Flat `configurations` dict keyed by opaque `"project_key/config_key"`.
  Each entry is self-describing (includes project_key, config_key, type,
  tool properties). Profiles reference configurations by cache key.
- `deploy_state` dict keyed by normalized absolute destination path. Tracks
  which source config unit's artifact was last deployed to each destination.
  Cleaned when source config units are deleted/cleaned.
- **Purely a serialization format.** At runtime, domain objects (ConfigUnit,
  Profile) own all mutable state as first-class fields. The cache file is
  generated from domain objects on save via `serialize()` methods. After
  deserialization, the cache data is consumed and discarded — no runtime
  code reads from it.
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
   operation is in flight. The UI displays "cleaning" when the action is
   a clean (reset state, keep cache skeleton) vs "deleting" when it is a
   full delete (remove cache entry entirely). ConfigUnit tracks the reason
   via `mark_deleting(flag, reason)`.
6. The `unknown` state means the build directory may be partially deleted
   (e.g., subprocess was killed, or files were locked on Windows). The only
   user actions available from `unknown` are delete and clean (retry).
   Build and configure are blocked.

### 3.2 Workspace Lifecycle

The workspace has three states:

| State | Meaning |
|-------|---------|
| `uninitialized` | No workspace loaded. All queries return nil. |
| `initializing` | Async file reads in progress. Queries return nil. |
| `initialized` | Files read, parsed, merged. Workspace is usable. |

**Initialization flow:**

1. `setup()` is called — workspace enters `initializing`.
2. Three files are read asynchronously (loomworks.json, user.json,
   cache.json) via libuv non-blocking I/O.
3. On completion: parse, validate, merge (without tool detection).
4. Workspace enters `initialized`. File watchers are started.
   `workspace_changed` event is emitted.
5. Tool detection starts as an independent background task (see §3.3).

`setup()` returns immediately. Callers must not assume the workspace
is available synchronously after `setup()` returns.

### 3.3 Tool Detection Lifecycle

Tool detection is orthogonal to workspace initialization. It has
three states:

| State | Meaning |
|-------|---------|
| `not_scanned` | Detection has not run. Tool entries unavailable. |
| `scanning` | Async detection in progress. |
| `scanned` | Detection complete. Tool entries available. |

Detection starts automatically after the workspace reaches
`initialized`. On completion, the system remerges and emits
`tools_detected`. The UI refreshes to show tool entries.

Manual re-scan (`rescan_tools()` / `L` key) transitions from
`scanned` → `scanning` → `scanned`, clearing and rebuilding the
in-memory tool cache.

During `scanning`, profile materialization (which requires detected
tools) waits for detection to complete before proceeding.

### 3.4 Cache state names vs ConfigUnit state names

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

**Trigger**: `ConfigurationSet:activate()`, `build()`, `configure()`, `<CR>` in
UI, or `p` key (pinned).

**Process (set-based profiles)**:
1. Receive structured data: set_name and optional tool_entry (tool_key,
   tool_data, tool_label, tool_mod_type)
2. Look up set_name in `configuration_sets` → mappings
3. For each project in the mappings:
   - Compute config_key (variant + tool_key for keyed modules)
   - Create skeleton cache entry if absent
4. Write profile entry (with `configuration_set` and tool fields) to
   `cache.profiles`
5. Save cache, trigger remerge

**Process (pinned profiles)**:
1. Property-based idempotency check: scan existing pinned profiles for one
   that references this ConfigUnit. If found, return it (no-op).
2. Create skeleton cache entry if absent (updates ConfigUnit directly)
3. Generate profile key via `cache.next_available_key()` to avoid collisions
4. Write profile entry (with `configuration_set = nil` and `mappings`) to
   `cache.profiles`
5. Create Profile and ProfileProject objects directly (no remerge needed)
6. Save cache

**Idempotent**: no-op if a pinned profile already references this ConfigUnit.

### 4.2 Activation

Activation makes a profile the "active" profile. The active profile determines:
- Which configurations are shown in `buf_status()`
- Which tool/config the LSP integration uses
- Which profile is highlighted with `LoomworksActive` in the status page

**Process**:
1. For new profiles: `ConfigurationSet:activate(tool_entry)` finds or
   materializes the profile, then activates it via the Profile object
2. For existing profiles: `Profile:activate()` writes `active_profile` to
   `loomworks.user.json` and triggers remerge (fires `active_set_changed`)

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

**Case sensitivity**: On Windows (case-insensitive filesystem), all path
normalization lowercases the path to ensure reliable comparisons. This
affects build dir matching, prefix checks, stray detection, and the build
dir reverse index / operation locks. Cached build_dir values retain their
original casing for display, but all comparisons use the lowercased form.

**Case collision prevention**: Project keys and configuration set names that
differ only by case would produce the same build directory path on
case-insensitive filesystems. The system warns on parse (loomworks.json
load) and rejects at runtime (`add_project`, `add_configuration_set`) to
prevent silent directory collisions.

**Shared build directory protection**: Multi-config generators (e.g., Ninja
Multi-Config, Visual Studio) share a single build directory across multiple
configurations (Debug and Release produce output in the same directory,
selected at build time via `--config`). When deleting a configuration that
shares a build directory with other configurations:

1. A reverse index (`_build_dir_refs`) maps each normalized build directory
   to the set of cache keys that reference it. Rebuilt during every remerge.
2. Before adding a directory to the deletion queue, subtract the cache keys
   being deleted in the current batch from the ref set.
3. If remaining refs > 0 → skip the directory (don't rm -rf). The cache
   entry is still removed/reset, but the filesystem directory is preserved.
4. The user is notified: "Skipped deleting {dir} — still referenced by
   {N} config(s)".

**Invariant**: a build directory is only deleted from the filesystem when no
remaining cache entries reference it after the current deletion batch.

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

### 4.8 Configuration Rename Propagation

When a project configuration is renamed (old_name → new_name) via the
config editor, all references are updated atomically:

1. **Config**: rename in `type_config.configurations`, update `inherits`
   references in sibling configs, update `configuration_sets` mappings for
   this project (saved to user.json; published to loomworks.json on `:w`)
2. **Cache entries**: rekey `cache.configurations` entries matching
   `project_key + old variant` → new config_key, update `variant` and
   `config_key` fields. **Build directory is preserved as-is** (the old
   path stays in the cache — the system accepts any build_dir path)
3. **Profile configurations arrays**: replace old cache keys with new ones

On next configure after rename, the module resolves a fresh build directory
using the new name. If the computed path collides with an existing directory
on disk, a numeric suffix is appended (`-2`, `-3`, ...) to ensure uniqueness.

**Cached build dir preference**: When a cache entry already has a
`build_dir`, task generation uses the cached path instead of recomputing.
This preserves the existing build directory after rename until the user
explicitly deletes and reconfigures.

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

### 5.3 Build Directory Operation Queue

Multiple configurations may share a single build directory (multi-config
generators). Concurrent operations on the same build directory can corrupt
the build. The build dir operation queue prevents this:

**Lock types**:
- **Exclusive** (configure, delete, clean): only one at a time, blocks all
  other operations on that build directory
- **Shared** (build): concurrent with other builds, queues behind exclusive
  operations

**Behavior**:
1. Before starting a task, the system acquires a lock on the task's build
   directory (if it has one).
2. If the lock can be acquired immediately, the task starts.
3. If the lock cannot be acquired, the task is queued and starts
   automatically when the lock becomes available.
4. When a task completes or is disposed, the lock is released.
5. On release, the system dequeues and runs the next compatible
   operation(s). Multiple consecutive shared operations are batched.

**Queue ordering**: FIFO. Shared operations are batched (multiple shared ops
run concurrently when dequeued), but shared batching stops at an exclusive
boundary.

**Scope**: The build dir lock is a separate layer from task readiness
(section 5.1). Readiness checks ConfigUnit state; the build dir lock gates
actual task launching to prevent filesystem corruption.

**UI hint**: When an operation is queued (waiting for a build dir lock),
the configuration shows "(queued)" in the status display.

### 5.4 Profile-level operations

All user-initiated actions (build, configure, clean, delete) are tracked
as Operation objects for progress reporting and UI scoping. An Operation
is a first-class object that:

1. Is created when a user initiates an action
2. Watches the affected ConfigUnits' state changes
3. Completes when ALL units reach their target state (or fail)
4. Produces a single result message (e.g., "built in 1m23s", "cleaned in 3s")

Operations have two completion modes:
- **Rank mode** (build/configure): uses a state hierarchy where higher
  states imply lower ones (e.g., "building" satisfies a "configured"
  target). Completes when units reach or exceed the target state.
- **Deletion mode** (clean/delete): completes when the `_deleting` flag
  clears on all affected units. Success if units return to "unconfigured",
  failure if they end up in "unknown" state (partial deletion).

Multiple Operations can coexist — they are independent objects, not a
single slot on Profile. This means overlapping actions on different
profiles don't clobber each other.

**Preemption rules**:
- Clean/delete **cancel** any active build/configure Operations on the
  same ConfigUnits (stopping their overseer tasks).
- Build/configure issued during a clean/delete are **deferred** via
  `after_deletions()` until the deletion Operation completes.

**UI scoping rules**:
- **Spinner**: shown on any profile with running ConfigUnits or an active
  Operation (including clean/delete Operations)
- **Orange highlight + timer/progress**: only on profiles with an active
  Operation (the profile that initiated the action)
- **Last operation message**: displayed after the profile name when no
  operation is active

Individual task completions produce no user-visible notifications.
Operation completion produces a single notification.

The `profile` field on an Operation is optional — config-level clean/delete
may not have a profile context. The `deletion_started`, `deletion_completed`,
and `deletion_failed` events are still emitted from `_run_deletion` for
external consumers, but fidget and the status page use Operation events
exclusively.

### 5.5 Progress tracking

- Each ConfigUnit tracks progress from a module-specific progress parser
  (e.g., ninja's `[n/m]` output)
- Profile-level progress is aggregated across all ProfileProjects:
  - Configure phase counts as 10% of total work
  - Build phase counts as 90% of total work
  - Percentage is averaged across all running projects
- Progress is displayed as `[n/m]` per-config and `N%` per-profile

### 5.6 Deletion waiter pattern

If a build/configure action is requested while a deletion Operation is
active:

1. `has_pending_deletions()` checks for active clean/delete Operations
2. Action is deferred via `after_deletions(fn)`
3. When the last deletion Operation completes, deferred actions are
   flushed in order

### 5.7 Task readiness: unknown state

Configs in `unknown` state block build and configure actions. The user must
issue a delete or clean first to resolve the unknown state. The UI should
indicate this restriction.

---

## 6. UI — Status Page

### 6.1 Layout

The status page opens as a floating window (default 100 columns, 90%
editor height). Window position and size can be configured via `setup()`
options or overridden per `open()` call — the `win` table is passed
directly to `Snacks.win`. The page contains these sections in order:

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
| `<CR>`  | enter       | Open action picker on nearest actionable node |
| `b`     | build       | Build (walks up to nearest node with `on_build`) |
| `c`     | configure   | Configure (walks up to nearest node with `on_configure`) |
| `p`     | pin         | Pin configuration as pinned profile |
| `o`     | options     | Show build options float (on configured project nodes) |
| `t`     | task        | Open overseer task output for nearest config (float) |
| `R`     | rebuild     | Clean + build (destructive, with confirmation) |
| `C`     | clean       | Run module clean tasks, reset to configured (with confirmation) |
| `D`     | delete      | Delete profile or configuration (destructive, with confirmation) |
| `N`     | create_workspace | Create a new workspace (loomworks.json) from cwd |
| `L`     | load        | Load workspace from cwd / rescan tools |
| `<C-n>` | nuke        | Reset workspace: delete `.nvim/build/` + cache, reload (destructive, with confirmation) |
| `P`     | publish     | Toggle publish flag on nearest publishable item |
| `U`     | delete_user | Delete user.json and reload (with confirmation) |
| `:w`    | (write)     | Publish: write published items to loomworks.json |
| `?`     | help        | Show help dialog |
| `q`     | (close)     | Close the status page |

**Action dispatch**: For `build`, `configure`, `rebuild`, `clean`, `delete`,
`pin`, and `options`, the tree walks upward from the cursor line to find the
nearest node that has the corresponding `on_<action>` callback. This means pressing
`b` on a child detail line triggers the build action of the parent node.

**Action picker (`<CR>`)**: The Enter key walks up to the nearest widget with
`on_*` callbacks, collects all available actions, and opens `vim.ui.select`
with the action list. The `enter` action label is context-dependent, set by
the section renderer via the `enter_label` field on the widget:
- Profile nodes: "Activate"
- Config set tool entries: "Activate"
- Project config/tool nodes: "Open task output"

The picker is skipped (direct invoke) when:
- The widget has `direct = true` (sentinel lines), OR
- Only one action exists on the widget (no other actions to discover)

**Sentinel lines**: Interactive `item` nodes that appear at the end of
sections to provide discoverable create/add flows. Sentinels have
`direct = true` on the widget, so Enter invokes `on_enter` immediately.
- **Profiles section**: `▸ Create new profile` — opens the profile creation
  multi-step picker (config set → tool → materialize). Shows "No projects
  yet." when no projects exist.
- **Projects section**: `▸ Add project` — opens the project browser float.

**Destructive action highlighting**: `R`, `C`, `D`, `U`, `<C-n>` keys are
highlighted with `DiagnosticWarn` in the help dialog.

### 6.4 Action Hints

Action hints show available keys close to the actionable items. Hints use
`Comment` highlight. Format: `[key] label  [key] label  ...` — keys in
brackets, separated by double spaces.

**Header hint**: After the Root line, a `Comment` leaf shows global actions:
`[?] help  [L] load  [<C-n>] reset`

**Group header hints with `[t]`**: Profile project groups also include `[t] task output`.

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
| Configurations: | Projects | `[b] build  [c] configure  [p] pin  [o] options  [R] rebuild  [C] clean  [D] delete` |

### 6.5 Profiles Section

Shows all materialized (cached) and explicit profiles. Profiles only appear
here when they exist in the cache or are declared in the config.

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
| Has active Operation + active | `LoomworksActive` |
| Has active Operation + not active | `LoomworksRunning` |
| Active (no operation) | `LoomworksActive` |
| Failed status | `LoomworksFailed` |
| Unconfigured | `LoomworksUnconfigured` |
| Otherwise | `LoomworksConfigured` |

Note: "Has active Operation" means this profile initiated the action.
Profiles that share ConfigUnits with the initiating profile show spinners
(from running ConfigUnit state) but not the orange highlight or timer.

**Profile children** (when unfolded):
- Set name (with warning if orphaned/stale) — only for set-based profiles
- Tool label (with generator/compiler details)
- Last operation message
- Projects sub-group:
  - Each project: `project_key [module_type] → variant {progress}` with status highlight
  - When unfolded: status, build dir, cmake details (generator, compiler)

**Profile actions**:

| Node type | `<CR>` | `b` | `c` | `t` | `R` | `C` | `D` |
|-----------|--------|-----|-----|-----|-----|-----|-----|
| Profile | activate | build all | configure all | — | clean+build all | clean all | delete with dialog |
| Project under profile | open task output | build config | configure config | open task output | clean+build config | clean config | delete config with dialog |

**Sentinel: Create new profile**

After the profile list (or as sole content when empty), an interactive item:
```
▸ Create new profile
```
Enter opens the profile creation multi-step picker:

1. **Pick configuration set**: Shows existing config sets from the
   workspace config, plus auto-detected options from
   `generate_default_config_sets()`. Auto-detected options are labeled
   `"Name (auto-detected)"` with a mapping summary. Selecting an
   auto-detected option writes it to user.json via
   `add_configuration_set()` before continuing.

2. **Pick tool** (skipped if module has no keyed tools, or only one tool
   detected): Shows available tools from `detect_tools()`.

3. **Materialize**: Calls `config_set:ensure_profile(tool_entry)` to
   create the profile in cache. Auto-activates only when this is the
   first profile in the workspace; otherwise just creates it.

When no projects exist, the sentinel is replaced with:
```
No projects yet. Add projects first.
```

### 6.6 Orphaned Items Section

Shows orphaned cached configurations and stray build directories. Visible
when either type exists (hidden otherwise — the common case).

**Title**: `Orphaned Items` with `Title` highlight.

**Orphaned configurations**: cached configs with build state not referenced
by any profile. Grouped by project key (sorted alphabetically). Each
project is a foldable node; each config within is a foldable node showing
the config key and its status.

**Stray build directories**: directories under `{root}/.nvim/build/` not
referenced by any cache entry. Detected via top-down pruning: the scan
reports the highest-level directory whose entire subtree contains no cache
entries. Directories that ARE cache entries (or parents of cache entries)
are skipped. Shown as flat items with `(stray)` suffix.

```
Orphaned Items  [D] delete

  ▶ App
    ▶ Debug:ninja-gcc-12 (built)
      Status: built
      Build dir: .nvim/build/App/Debug
  .nvim/build/OldProject (stray)
  ▸ Clean all
```

**Highlight**: Project nodes use `LoomworksUnconfigured`. Config nodes use
`resolve_config_status()` highlights. Stray dir items use
`LoomworksUnconfigured`.

**Actions**: `D` (delete) is mapped on config nodes and stray dir items.
All other action keys (`b`, `c`, `R`, `C`, `p`) are not bound — orphaned
items cannot be built, configured, or pinned. Deletion shows the standard
confirmation dialog.

**Sentinel: Clean all**

After the last orphaned item:
```
▸ Clean all
```
Enter shows a confirmation dialog listing:
- All orphaned cached configurations (with state and build dirs)
- All stray build directories

On confirm: deletes orphaned cache entries + build dirs via `_run_deletion`,
then deletes stray build dirs. If nothing to clean, shows a notification.

### 6.7 Configuration Sets Section

Shows configuration sets from the merged config (loomworks.json + user.json).
Only appears when sets exist.

**Set node display**:
```
{fold_char} {modified_tag}{set_name}
```

Where `{modified_tag}` = "+" if the set is modified (see §2.4), empty
otherwise. Shared-only sets (not in user.json) are dimmed (`Comment`).

Highlighted with `LoomworksActive` if the active profile belongs to this set,
otherwise `LoomworksActionable` (or `Comment` if shared-only).

**Set node actions**:

| Action | Behavior |
|--------|----------|
| `<CR>` | Action picker: Edit mappings, Create profile from set, Delete |
| `D`    | Delete config set with confirmation dialog |

**Config set editing** (`<CR>` on a set node):

Opens a dedicated config set editor dialog. Shows each project in the
workspace with its current variant mapping and available configurations
(from module.info). The user can change each mapping via `vim.ui.select`
or set it to "None" to remove the mapping. Accept (`y`) applies changes
via `update_config_set_mapping()` for each changed mapping. Cancel (`q`)
discards changes.

Changed mappings may orphan existing cached configs (old variant no longer
referenced). This is intentional — orphans are cleaned explicitly via the
"Clean all orphaned items" action in the Orphaned Configurations section.

**Config set deletion** (`D` on a set node):

Shows a confirmation dialog listing:
- Profiles that reference this set (will become orphaned-set)
- Warning that cached configs will become orphaned

On confirm: `remove_configuration_set()`. Profiles that referenced the set
become orphaned_set. Cached configs for those profiles become orphaned. No
immediate deletion of cache entries — the user cleans via "Clean all orphaned
configs" in the Projects section.

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

**Sentinel: Create configuration set**

After the last config set, an interactive item:
```
▸ Create configuration set
```
Enter prompts for a name via `vim.ui.input`, then opens the config set
editor dialog pre-populated with auto-detected mappings (same
`compute_initial_mappings` logic used for add-project). On accept:
`add_configuration_set(name, mappings)`.

### 6.8 Projects Section

Shows all projects from the active set, including orphaned projects. Projects
are sorted alphabetically with orphaned projects at the end.

**Project node display**:
```
{fold_char} {modified_tag}{project_key} [{type}] {orphan_tag} {refresh_tag}
```

Where:
- `{modified_tag}` = "+" if any child or the project declaration is modified
  (see §2.4), empty otherwise
- `{orphan_tag}` = "(orphaned)" if in cache but not in config
- `{refresh_tag}` = "!" if `needs_refresh` is true

**Shared-only items** (exist only in loomworks.json, not in user.json) are
displayed with `Comment` highlight (dimmed). Module-generated default
configurations are also dimmed. Dimmed items become normal on first
interaction (auto-copied to user.json).

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

**Launch configurations sub-group**

After the configurations group, each non-orphaned project shows a
"Launch:" group listing its launch configurations.

Each launch config item shows `{name}  {command} {args}`. Actions:

| Action | Behavior |
|--------|----------|
| `<CR>` | Edit launch config (opens launch editor dialog) |
| `D`    | Delete launch config with confirmation |

A "Add launch config" sentinel opens the launch editor for a new config.

The **launch editor dialog** edits: name, command, args (space-separated),
working directory, and environment variables (key=value pairs). Env vars
can be added (`▸ Add variable`) and removed (`D`). Inline name validation
prevents duplicates. Accepts with `y`, cancels with `q`.

**Sentinel: Add project**

After the last project (or as sole content when no projects exist), an
interactive item:
```
▸ Add project
```
Enter opens the project browser float (Phase 1). Replaces the former `A`
keybinding.


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

### 6.12 Options Float

Triggered by `o` on a configuration or tool entry node in the Projects
or Profiles section. Opens a floating window showing the project's build
options for that configuration. Only available for configured projects
with a cached build directory.

**`Core:get_project_options(project_key, config_key) → (OptionGroup|Option)[]|nil`**

Resolves the build directory from cache and delegates to the module's
`get_options()`. Returns nil if the project is not configured or the
module does not support options.

The float uses a Tree widget with foldable groups. The module returns a
tree of `OptionGroup` and `Option` nodes. Each group shows its label and
child count. Each option shows `key = value`. BOOL values are highlighted
(ON = green, OFF = dimmed). Options with helpstrings show them as
children when unfolded. Options with choices show them in parentheses
after the value. Fold/unfold with `<Tab>`.

The float is read-only. Close with `q` or `<Esc>`.

### 6.13 Project Browser

The project browser is a float opened from the "Add project" sentinel line.
It scans workspace subdirectories asynchronously and shows detected project
types using each module's `detect()` method.

**Layout**: Tree widget in a `Snacks.win` float. Title: "Add Project".

**Entry display**: Each directory entry shows its name followed by detected
type tags: `NativeDemo  [cmake: CMakeLists.txt]`. Directories matching
multiple modules show all tags. Already-added projects show `✓` with
`DiagnosticOk`. Directories with no detection show `Comment` highlight.

**Async scanning**: On open, `modules.scan_directory_async()` scans the
workspace root. On fold open, subdirectories are scanned lazily. Results
are cached in a browser-local dict. Pending scans show "scanning...".

**Filtered directories**: `.git`, `.nvim`, `.cache`, `.vs`, `.vscode`,
`node_modules`, `build`, `out`, `__pycache__`, and all hidden directories
(starting with `.`) are excluded from scanning.

**Keybindings**:

| Key     | Action  | Behavior |
|---------|---------|----------|
| `<CR>`  | enter   | Picker with Add/Remove by module type (see below) |
| `d`     | remove  | Remove project from workspace (with confirmation) |
| `r`     | refresh | Clear scan cache and re-scan |
| `q`     | close   | Close the browser |

**Project key derivation**:
- Root-level directories: basename as key, `path` field omitted
- Nested directories: relative path (with `/` → `_`) as key, explicit `path`
  field

**Enter picker**: Each browser entry has a context-dependent picker:
- Unadded types show `Add [type]`
- Already-added types show `Remove [type]`
- Single add action: always shows picker (user confirms)
- Mixed state: both add and remove options appear

**Configuration mapping dialog**: When adding a project to a workspace
that already has configuration sets, a mapping dialog opens instead of
adding immediately.

The dialog layout depends on the module type and workspace state:

**Keyed module, no tool selected** — tool row first, no mappings:

```
  Add "lumets" [cmake]

  Tool:  None ▸

  Project will be added without configuration mappings.

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool selected** — tool row first, then mappings:

```
  Add "lumets" [cmake]

  Tool:  Ninja - GCC 12 ▸

  Debug     Debug ▸
  Release   Release ▸

  Profiles to upgrade:
    Debug → Debug:ninja-gcc-12

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool inherited** — when existing profiles already have
a tool (e.g. adding a second cmake project), the tool is inherited
automatically. No tool row; mappings only:

```
  Add "NewLib" [cmake] — Map configurations

  Debug     Debug ▸
  Release   Release ▸

  [Enter] change  [y] accept  [q] cancel
```

**Non-keyed module** — mappings only:

```
  Add "Frontend" [typescript] — Map configurations

  Debug     development ▸
  Release   production ▸

  [Enter] change  [y] accept  [q] cancel
```

The profile upgrade preview shows only profiles whose config set has
a non-None mapping for the new project.

- Enter on a mapping row opens `vim.ui.select` with configurations + "None"
- Enter on the tool row opens `vim.ui.select` with detected tools
- `y` accepts: chains decomposed operations (see below)
- `q`/Esc cancels: project is NOT added
- Skipped when no config sets exist or project has no detectable configs
- No success notifications — UI state changes are sufficient. Only
  errors are shown via `vim.notify`.

**Tool detection gating**: When the module has keyed tools, the project
browser ensures tool detection has completed before opening the mapping
dialog. If detection is still running, the dialog opens in the callback
after detection completes.

**Decomposed add-project operations**: On accept, the mapping dialog
chains three atomic operations. Each operation saves to disk and
remerges independently. Each intermediate state is valid — if the
process crashes between steps, no data is lost or corrupted.

1. `ws:add_project(key, type, path)` — adds the project entry to
   user.json. Project shows as unmapped.
2. For each config set with a non-nil mapping:
   `ws:update_config_set_mapping(set, key, variant)` — adds one
   mapping to one config set.
3. If a tool was selected or inherited:
   `ws:upgrade_profiles_for_tool(tool_entry)` — upgrades cached
   no-tool profiles to keyed profiles (renames, adds tool fields,
   creates skeleton cache entries). Extends existing keyed profiles
   with skeleton entries for the new project.

**Cache cleanup on removal**: The removal confirmation dialog shows all
cached configurations for the project that will be deleted. Entries with
build state (configured/built/failed) are listed with their build
directories. Skeleton entries (unconfigured) are silently included.

**Profile downgrade on removal**: When removing a project whose module
has keyed tools, the project browser checks whether it is the last
project of that module type. If so, the removal confirmation dialog also
shows a profile rename preview.

Example dialog (keyed project with cached configs):

```
  Remove project: lumets

  This removes the project from the workspace (user.json and, on next
  `:w`, from loomworks.json if published).

  Will delete cached configurations:
    lumets / Debug:ninja-gcc-12  (built)  .nvim/build/lumets/Debug
    lumets / Release:ninja-gcc-12  (configured)  .nvim/build/lumets/Release

  Profiles to rename:
    Debug:ninja-gcc-12 → Debug
    Release:ninja-gcc-12 → Release

  Press y to confirm, q to cancel
```

After confirmation:
1. `ws:remove_project(key)` removes the project from config and config sets.
2. Cached configurations for the project are deleted (entries removed from
   cache, build directories deleted asynchronously via safe deletion).
3. `ws:downgrade_profiles_from_tool(mod_type)` strips tool suffixes from
   affected profiles when the last keyed-module project is removed.

This is not "auto-clean" — it is an explicit user action with a
confirmation dialog showing exactly what will be deleted.

**File mutation**: All changes write to `loomworks.user.json` via Workspace
mutation methods. Each method saves and remerges independently. Published
items are written to `loomworks.json` only on explicit `:w` (see §2.4).

Available Workspace mutation methods:
- `add_project(key, type, path?)` — add a project entry
- `remove_project(key)` — remove project + clean up config sets
- `update_config_set_mapping(set_name, project_key, variant)` — update
  one mapping in a config set
- `add_configuration_set(name, mappings)` — add a config set
- `remove_configuration_set(name)` — remove a config set
- `upgrade_profiles_for_tool(tool_entry)` — upgrade no-tool profiles
  to keyed profiles; extend keyed profiles with new project entries
- `downgrade_profiles_from_tool(mod_type)` — strip tool from profiles
  when last project of a keyed-module type is removed
- `compute_downgrade_preview(project_key)` — compute profile renames
  that would occur if a project were removed (pure query, no mutation)

### 6.14 Auto-refresh

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
| `operation_started`    | `{ profile_key, action, operation }` | Profile-level action begins |
| `operation_finished`   | `{ profile_key, success, message, operation }` | Profile-level action ends |
| `task_result`          | `TaskResult` | Individual task completes |
| `task_started`         | (via ConfigUnit) | Task registered on a unit |
| `task_stopped`         | (via ConfigUnit) | Task unregistered |
| `task_progress`        | (via ConfigUnit) | Progress update |
| `deletion_started`     | `DeletionItem[]` | Deletion operation begins |
| `deletion_completed`   | `DeletionItem[]` | Deletion operation ends (success) |
| `deletion_failed`      | `{ items, errors }` | One or more build dir deletions failed |
| `tools_detected`       | `tools_by_type` | Tool detection completed |

Events pass data directly to listeners — no need to re-query, no race
conditions.

---

## 9. Module Interface

A module is a handler for a project type. Modules implement a standard
interface that the core system calls for project discovery, task generation,
and staleness detection.

### 9.1 Required methods

**`detect(abs_path) → { marker }|nil`**

Detect whether a directory looks like a project of this module type. `abs_path`
is the absolute directory path. Returns `{ marker = "filename" }` identifying
the marker file that triggered detection, or `nil` if not detected.

- **cmake**: checks for `CMakeLists.txt`
- **typescript**: checks for `tsconfig.json` first, then `package.json` with
  a `typescript` dependency
- **ets**: checks for `build-profile.json5`

Used by the project browser for auto-detection. Lightweight check — no
subprocess spawning, no deep file parsing.

**`validate(path, config) → { valid, warnings[] }`**

Check whether the project directory is valid for this module type. `path` is
the absolute project directory. `config` is the type_config from the
workspace config (the value of the `"cmake": {}` key).

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

**`detect_tools(callback)`**

Detect available tools for this module type asynchronously. Calls
`callback(tool_entries)` when detection is complete. Each entry has:
- `tool_data`: opaque table of tool properties (stored in cache)
- Additional fields added by core: `tool_key`, `tool_label`

Non-keyed modules (ets, typescript) may call the callback
immediately with a single entry containing empty `tool_data`.

Modules that spawn subprocesses (e.g., cmake compiler detection)
must use non-blocking APIs (libuv spawn or jobstart) and chain
results sequentially to avoid flooding the OS with processes.

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

**`has_keyed_tools`** (boolean, static property)

Declares whether this module's tools produce distinct build artifacts
requiring separate cache entries. `true` for cmake, `false`/nil for
ets and typescript. Used by merge to construct config keys without
requiring tool detection to complete first.

### 9.3 Variant mapping

**`map_variant(variant_type, available_configs) → string|nil`**

Map a semantic variant type to a configuration name from the project's
available configurations. Used by `generate_default_config_sets()` to
compute cross-project configuration sets automatically.

Variant types (defined by core, queried in order):
- `"debug"` — development/debug build
- `"release"` — optimized production build
- `"release_debug"` — optimized with debug info (optional)

Each module knows its own naming conventions:

| Module | debug | release | release_debug |
|--------|-------|---------|---------------|
| cmake | `"Debug"` (case-insensitive) | `"Release"` | `"RelWithDebInfo"` |
| typescript | `"development"`, then `"default"` | `"production"`, then `"default"` | — |
| ets | `"debug"` | `"release"` | — |

**Single-config fallback**: If only one configuration exists, return it for
any variant type (the project builds the same way regardless).

Returns `nil` when no matching configuration exists and the project has
multiple configurations.

### 9.4 Optional methods

**`progress_parser(project?, active_config?) → string|nil`**

Return the name of a registered progress parser (e.g., `"ninja"`), or `nil`
if the module has no progress tracking. Parameters are optional — modules
may ignore them or use them to select a parser based on context.

**`get_options(build_dir, config?) → (OptionGroup|Option)[]|nil`** *(optional)*

Return the user-facing build options as a tree of groups and options.
`OptionGroup` has `label` and `children` (nested groups or options).
`Option` has `key`, `value`, `value_type` (`"bool"`, `"string"`, `"path"`,
`"filepath"`), optional `helpstring`, and optional `choices`. `config` is
the module's type_config from the workspace config (e.g., the cmake block).

Only options meaningful to the user are included — internal/computed
variables are excluded. Returns nil if the project is not configured or
has no options. Called on demand, not cached.

The cmake module supports `option_groups` in its type_config to map
variable name prefixes to group paths (e.g.,
`"GFX": ["Media", "Graphics"]`). CMAKE_ prefixed variables are
automatically separated into a "CMake Options" group.

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
  and no configurations are declared in the workspace config**
- Overrides in the `configurations` block add to or override
  preset-derived configurations

### 9.5 CMake File API integration (cmake module)

The cmake module uses CMake's file-based API (codemodel v2) to discover
build targets after configure.

**Query setup**: The query files
`<build_dir>/.cmake/api/v1/query/codemodel-v2` and `cache-v2` are created
before the configure task runs (in the task builder). These are empty
markers — their presence tells CMake to write reply data on every
configure. The codemodel reply provides targets; the cache reply provides
build options.

**Reply parsing**: After a successful configure, core calls
`parse_file_api(build_dir, config_name?)` on the module. The cmake module
reads the codemodel reply from `<build_dir>/.cmake/api/v1/reply/`,
extracts project-owned targets, and returns them. On startup, existing
build directories are scanned asynchronously via `parse_file_api_async`.

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

**Storage**: Targets are runtime-only data stored on `ConfigUnit.targets`
as `Target` objects (not persisted in cache). They are re-parsed from the
file-api reply on startup (async) and after each successful configure
(sync). The entire targets dict is replaced on every parse (not merged).
Each `Target` object holds the target id, type, dependencies, artifact
path, and a back-reference to its owning `ConfigUnit`.

### 9.6 Per-target builds

Each profile can have a **default target** — a single executable target
that `build_target()` builds instead of the full project.

**Default target storage**:
- `loomworks.user.json`: `default_target = { "<profile_key>": { "project": "<key>", "target": "<id>" } }`
- Published profile definitions: `default_target = { "project": "<key>", "target": "<id>" }`
- User.json overrides published config.

**Resolution**: `Profile:default_target()` returns a `LaunchTarget` object
that holds direct references to the `Project`, `ConfigUnit`, and `Target`
objects. No key-based lookups at runtime.

**Build flow** (`build_target()` API):
1. Get active profile's default target.
2. If not set: show `vim.ui.select` picker with executable targets.
   Picker includes "None" to clear and "Default" to revert to
   published config setting. On selection, sets default and builds.
3. If set but stale (target no longer exists): notify and show picker.
4. If valid: `Target:build()` delegates to the module's
   `build_target_task()` (e.g., cmake adds `--target <name>`).

**Module interface**: `build_target_task(project_ctx, target_id)` returns
an overseer task definition for building a single target. Falls back to
full build if the module doesn't implement it.

### 9.7 Target launching

Each profile can have a default launch target — a configuration that
defines how to run the project after building. Two types:

**Module targets** (cmake executables): `Target:launch()` resolves the
artifact path from the build directory and runs it via overseer.

**Command-type launches** (`launch` section in project config): Named launch
configurations per project with command, args, env, working_dir, deploy.

```json
"ScenePluginTest": {
    "typescript": {},
    "launch": {
        "debug": {
            "command": "node",
            "args": ["assets/scripts/app.js"],
            "working_dir": "${workspace_root}/ScenePluginTest",
            "env": {
                "NODE_PATH": "${workspace_root}/ScenePluginTest/Debug"
            }
        }
    }
}
```

**Variable expansion** in args, env values, working_dir, deploy destinations:
- `${workspace_root}` — absolute workspace root path
- `${build_dir}` — config unit's absolute build directory path
- `${config_set}` — active configuration set name
- `${variant}` — project's variant in the active config set
- `${project_path}` — project's relative path
- User-defined project variables (section 1.3.1) — resolved per
  configuration with inheritance. Expanded after built-in variables.

**Launch flow** (`launch_target()` API):
1. Stop any previously running launch target (single target at a time)
2. Get active profile's default target (LaunchTarget)
3. If buildable: build first (auto-configure if unconfigured or stale)
4. Resolve and execute deploy steps (section 9.8) — block on failure
5. Launch on success
6. Open overseer window for launch output
7. Track launched process for `stop_target()`

**Task cleanup**: When a new build/configure task starts on a ConfigUnit,
the previous completed overseer task is disposed. Same for launch tasks.
This prevents accumulation in overseer's task list while keeping running
tasks and the most recent output available.

**Default target storage** in user.json per profile:
```json
"default_target": {
    "Debug:ninja-gcc-12": {
        "project": "ScenePluginTest",
        "launch": "debug"
    }
}
```

### 9.8 Deploy Steps

Deploy steps ensure build artifacts from one config unit are copied to the
correct location before a launch target runs. They guarantee that the
launched process sees up-to-date files regardless of which configuration was
most recently built.

**Definition**: A deploy step is a declarative intent — "ensure artifact X
from source config unit Y is at destination Z, up to date, before launch."
Deploy steps are defined on launch configurations in the workspace config.

#### 9.8.1 Syntax

Deploy steps are a dict keyed by destination path, with source descriptors
as values:

```json
"App": {
    "typescript": {},
    "launch": {
        "debug": {
            "command": "node",
            "args": ["app.js"],
            "deploy": {
                "${build_dir}/native.node": {
                    "project": "NativeLib",
                    "target": "native_lib"
                },
                "${workspace_root}/shared/lib/": {
                    "project": "ConfigLib",
                    "configuration": "Release",
                    "path": "bin/config.dll"
                }
            }
        }
    }
}
```

**Destination key** (left side): path where the file should end up. Variable
expansion uses the **launch target's project context** (same variables as
launch config expansion, plus `${build_dir}`):

- `${workspace_root}` — absolute workspace root path
- `${build_dir}` — launch target's config unit's build directory
- `${project_path}` — launch target's project path (relative to root)
- `${variant}` — launch target's project variant in the active profile
- `${config_set}` — active configuration set name

If the destination ends with `/`, it is a directory — the source filename is
preserved. Otherwise the destination is a full file path (rename). Parent
directories are created automatically if they do not exist.

Path safety: `..` and `.` segments are rejected at parse time.

**Source descriptor** (right side): identifies which file to copy. Can be
a single descriptor or an array of descriptors (multiple sources to the
same destination directory).

```json
"${build_dir}/lib/": [
    { "project": "NativeLib", "target": "native_lib" },
    { "project": "ConfigLib", "path": "bin/config.dll" }
]
```

| Field | Required | Description |
|-------|----------|-------------|
| `project` | yes | Source project key |
| `target` | one of target/path | cmake target name — resolved to artifact path |
| `path` | one of target/path | file path relative to source build dir |
| `configuration` | no | Pin to a specific configuration; defaults to profile resolution |

**Duplicate destination keys**: JSON does not allow duplicate keys in an
object. If `loomworks.json` contains two entries with the same destination
key, the JSON parser silently keeps only the last one. Use the array
source format to copy multiple files to the same directory.

Source fields use **no variable expansion** — `target` is a cmake target
name resolved via the module, `path` is a literal relative path from the
source config unit's build directory.

#### 9.8.2 Source resolution

At launch time, each deploy step resolves its source within the active
profile's context:

1. Look up the source project by key
2. Determine the configuration:
   - If `configuration` is specified → use that variant name
   - If omitted → use the profile's configuration set mapping for the
     source project
3. Find the config unit for (source project, resolved configuration) in
   the active profile. The profile's tool mapping provides the tool.
4. Resolve the source file path:
   - `target` → look up the target in the config unit's targets dict →
     use `target.artifact` relative to the config unit's build directory
   - `path` → use as-is relative to the config unit's build directory
5. If any step fails (project not in profile, configuration not found,
   target not found, build dir is nil), the deploy step is **unresolvable**

**Unresolvable deploy steps block the launch.** The user is notified with
a specific error (e.g., "Deploy: NativeLib not in profile", "Deploy:
target native_lib not found"). The launch does not proceed.

#### 9.8.3 Freshness tracking

The system tracks which source was last copied to each destination. This is
necessary because mtime alone is insufficient — building Release after Debug
makes Release's artifact newer, but switching back to a Debug launch must
still copy the Debug artifact.

**Deploy record** (stored in cache.json `deploy_state` section):

```json
"deploy_state": {
    "C:/workspace/App/Debug/native.node": {
        "source_build_dir": "build/NativeLib/Debug:ninja-gcc-12",
        "source_rel_path": "native_lib.node",
        "source_mtime": "2026-03-31T10:00:00Z"
    }
}
```

Keyed by **normalized absolute destination path**. Each record tracks:
- `source_build_dir` — config unit id (relative build dir path) from which
  the file was last copied
- `source_rel_path` — relative path within that build dir
- `source_mtime` — mtime of the source file at the time of the last copy

**Freshness check** for each deploy step:

1. Resolve source → `(build_dir, rel_path)` → absolute source path
2. Look up deploy record for the expanded destination path
3. Copy is needed if ANY of:
   - No deploy record exists (never copied)
   - Destination file does not exist on disk
   - `source_build_dir` differs (configuration or tool changed)
   - `source_rel_path` differs (target artifact path changed)
   - Source file mtime is newer than recorded `source_mtime`
4. After successful copy, update the deploy record

Deploy records are domain state — deserialized from cache.json into
workspace-owned objects during remerge, serialized back on save. No raw
cache data is retained.

#### 9.8.4 Launch flow with deploy

The launch flow (section 9.7) is extended:

1. Get active profile's default target (LaunchTarget)
2. If buildable: build dependencies, then build self
3. **Resolve deploy steps** from launch config
4. **Execute deploy steps**: for each step, check freshness, copy if needed
5. If any deploy step fails (unresolvable, copy error) → **block launch**,
   notify user with error
6. Launch the target
7. Open overseer window for launch output

Deploy steps execute sequentially (order of dict keys). All deploy steps
must succeed before the launch proceeds.

#### 9.8.5 Cleanup on deletion/clean

When a config unit is deleted or cleaned (sections 4.6, 4.7):

1. Scan deploy records for entries where `source_build_dir` matches the
   affected config unit's build dir id
2. Delete the destination files (if they exist on disk)
3. Remove the deploy records from cache
4. Save cache

This ensures deployed artifacts do not outlive their source build
directories.

#### 9.8.6 Design for extension (not in v1)

The deploy system is designed for future extension:

**Cascade levels**: Deploy steps can be defined at multiple levels, with
more specific levels overriding less specific ones per destination key:

```
Project.deploy          → applies to all configs/launches of this project
  Configuration.deploy  → overrides project-level for this configuration
    Launch.deploy       → overrides config-level for this launch
```

A `null` value at a more specific level suppresses a parent-level deploy
step. v1 implements launch-level only.

**Action types**: The `deploy` dict currently implies a "copy" action.
Future actions (symlink, script execution) could be specified via an
explicit action field in the source descriptor.

**user.json deploy**: Deploy steps live in user.json as part of the
working copy. Published deploy steps are written to loomworks.json on `:w`.

---

## 10. LSP Integration

### 10.1 clangd cmd factory

`loomworks.lsp.clangd_cmd(base_cmd)` returns a function suitable for
lspconfig's `cmd` option. It resolves per-project:

1. **clangd binary**: project-level override (`cmake.clangd` in
   workspace config) > kit auto-detected clangd_path > default from base_cmd
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
  asynchronously (non-blocking)
- Creates `.nvim/loomworks.cache.json` if it does not exist
- Emits `workspace_changed` and `active_set_changed` events once
  initialized
- Starts asynchronous tool detection in the background
- Reports initialization and detection progress via fidget.nvim
  (if available)

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

9. **Idempotent materialization**: Materializing an already-cached profile
   is a no-op. `ConfigurationSet:activate()` finds the existing profile by
   property matching and skips materialization.

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

12. **Non-blocking initialization**: Workspace setup never blocks the
    Neovim UI thread. File reads use async I/O. Tool detection runs
    as a background task. Only JSON parsing and merge (both fast,
    CPU-bound operations) run synchronously within callbacks.
