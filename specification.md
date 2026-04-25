# loomworks.nvim — Specification

This document is the authoritative behavioral specification for loomworks.nvim.
It defines *what* the system does — data model, state machines, integration
contracts, and invariants — not how it is implemented. The implementation
(code) and architecture (ARCHITECTURE.md) must conform to this specification.

## Document layout

This file is the **core specification**. It describes contracts and
behavior that hold for any module, LSP integration, DAP integration,
or SDK provider. It does not name specific modules, tools, compilers,
or SDKs in normative prose — implementations are documented in
sibling files under `spec/`:

- [`spec/modules/`](spec/modules/) — per-module implementations (cmake,
  harmony, meson, typescript)
- [`spec/integrations/lsp/`](spec/integrations/lsp/) — per-LSP-server
  integrations (clangd, …)
- [`spec/integrations/debug/`](spec/integrations/debug/) — per-DAP-adapter
  contracts (codelldb, cppdbg, pwa-node, …)
- [`spec/sdks/`](spec/sdks/) — per-SDK-provider details (ohos, …)
- [`spec/ui.md`](spec/ui.md) — the status page, highlight groups, and
  winbar/statusline component

Section numbers inside `spec/*.md` files are local to each file and
restart at §1.

## Where does this change go?

| If the change is about… | Update… |
|--|--|
| What the data model means, the state machine, or core invariants | `specification.md` §1–§5, §15 |
| What modules, LSP servers, DAP adapters, or SDK providers must implement to plug in | `specification.md` §8–§11 (the contract sections) |
| Status page, highlight groups, winbar | [`spec/ui.md`](spec/ui.md) |
| How a single shipping module does its thing internally | the matching file in [`spec/modules/`](spec/modules/) |
| How a single LSP integration handles its server | the matching file in [`spec/integrations/lsp/`](spec/integrations/lsp/) |
| How a single DAP adapter is invoked | the matching file in [`spec/integrations/debug/`](spec/integrations/debug/) |
| How a single SDK provider detects, validates, and answers capability queries | the matching file in [`spec/sdks/`](spec/sdks/) |
| Adding a new module, LSP server, DAP adapter, or SDK provider | a new file under the corresponding `spec/` subdirectory; touch core only if the contract itself needs a new field or hook |
| A deferred / planned feature that is not yet implemented | [`BACKLOG.md`](BACKLOG.md), not core spec |

**Naming rule for core**: core sections forbid module / tool / compiler /
SDK / integration names in normative prose. Specific names may appear in
fenced "example" blocks when they aid reasoning, but never as the
authoritative description of behavior. The authoritative description
belongs in the matching `spec/` file.

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

A project is a sub-component of a workspace with a type (cmake, harmony,
typescript, etc.). Projects are declared in `loomworks.json` and/or
`loomworks.user.json` under `"projects"` (see §2.4 for the merge model).

- Key: the project identifier (typically the directory name).
- `path`: relative to workspace root, defaults to the key.
- `type`: determined by the inner key (`"cmake": {}` means type = cmake).
- A project may be **orphaned**: present in cache but absent from the current
  config (both loomworks.json and user.json). Orphaned projects are shown at
  the end of the Projects section with an "(orphaned)" label.

### 1.3 Configuration

Configurations live in two tiers, distinguished by canonical name
shape. The tier decides who owns the entry and what actions are
available on it.

**Auto-generated configurations** — emitted by the module from
project sources (build-profile.json5, CMakePresets.json, CMakeLists'
`CMAKE_CONFIGURATION_TYPES`, tsconfig variants). Canonical names take
the form `prefix:base`, where the prefix is chosen by the module:

  - `variant:` — built-in compile-mode variants (cmake/meson/typescript
    Debug/Release/RelWithDebInfo/MinSizeRel, typescript `default`)
  - `preset:` — CMakePresets.json entries (cmake)
  - `auto:` — project-file-derived configs (harmony's
    `auto:default-entry-arm64-v8a` from build-profile.json5)

Auto-gen configs are read-only — their contents are regenerated from
the module every load, never persisted. UI shows them in a dimmed
colour.

**User configurations** — declared by the user under
`<type>.configurations.<name>` in loomworks.json / user.json.
Canonical name is the bare name (no prefix, no `:`). A user config
typically carries `inherits: "<prefix:base>"` pointing at an
auto-gen to pick up a variant and extend it with options / toolchain
overrides. UI shows them in the normal colour with edit/rename/delete
actions.

**Namespace rule**: user-declared configuration names MUST NOT
contain `:` — that character is the tier separator. `config.validate`
rejects names containing it with a specific error pointing the user
to rename. A user config's `inherits:` reference, by contrast, uses
the full canonical name — `inherits: "variant:Debug"`, not bare
`"Debug"`.

References (configuration_set mappings, inherits values, default
target pointers) store the full canonical name verbatim. Orphan
references — pointers at a name no live Configuration matches —
render in yellow with a ⚠ badge and a rename/rebase action.

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

**Harmony configurations**: auto-generated from `build-profile.json5` as
the cross product of products × module targets × ABI filters. Each
canonical name is `auto:<product>-<target>-<abi>` (e.g.,
`auto:default-default-arm64-v8a`, `auto:ohos-default-armeabi-v7a`).
Products and targets come from the build-profile; ABI filters come
from the product's `externalNativeOptions.abiFilters`. Non-native
projects (no ABI filters) use `auto:<product>-<target>` without the
ABI suffix.

Each harmony configuration stores: `product` (product name), `target`
(build target name), `abi` (architecture string or nil), `mode`
(debug/release), `runtime_os` (HarmonyOS/OpenHarmony), `modules` (hvigor
module names), `module_name` (primary module for build dir path).

When `build-profile.json5` changes (product added, removed, ABI filters
changed), configurations that no longer match get `_source_missing`
treatment — they remain visible but marked as unavailable. New
combinations appear as new configurations.

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

- **Keyed tools** (cmake, meson): cache key = `"variant:tool_key"` (e.g.,
  `"Debug:ninja-gcc-12"`, `"Debug:gcc-14.2.0"`). Each generator+compiler (cmake)
  or compiler (meson) produces different build output.
- **Non-keyed tools** (harmony, typescript): cache key = `"variant"`. The tool
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

All profiles are **set-based** — they reference a configuration set and
derive their mappings from it on every remerge. Adding/removing projects
in the config automatically updates the profile.

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

### 1.8 Device

A device is a physical or emulated deployment target (phone, tablet,
emulator). Devices are identified by a **serial string** assigned by the
device connector tool (e.g., `hdc` for HarmonyOS, `adb` for Android).
The serial is stable across USB reconnections and emulator restarts.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `serial` | string | Unique device identifier (identity key) |
| `display_name` | string | Human-readable label (model name or serial) |
| `provider` | string | Module ID that owns this device type (e.g., `"harmony"`) |
| `state` | string | `"online"` or `"offline"` |
| `properties` | table | Opaque module-specific data (model, OS version, etc.) |

**Ownership and lifecycle**:

- Devices are **workspace-level** — they are physical hardware, shared
  across all profiles.
- Devices are **runtime-only** — discovered on demand via the module's
  `list_devices()` method (§11). Not persisted to cache or user.json.
- Discovery is triggered by: (1) opening the device picker in UI,
  (2) attempting to launch a device-requiring target with no device
  selected, (3) explicit `scan_devices()` API call.
- Between scans, vanished devices are marked `"offline"` (not removed).

**Profile device selection**:

Each profile may store an optional **device serial** (string). This is the
device selected for device-requiring launch targets in this profile.
Persisted in user.json alongside `default_target`. If the serial references
an offline or unknown device, the UI shows a warning.

Only modules with `has_devices = true` produce device-requiring targets.
Profiles in workspaces with no device-capable modules never show device
UI or store device selections.

### 1.9 loomworks.json Schema

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
    "NativeDemo": {
      "harmony": {
        "cmake_env": {
          "CORE_SUBMODULE_ROOT": "${workspace_root}/submodules"
        }
      }
    }
  },
  "configuration_sets": {
    "Debug":   { "App": "Debug",   "Frontend": "development", "NativeDemo": "default-default-arm64-v8a" },
    "Release": { "App": "Release", "Frontend": "production",  "NativeDemo": "default-default-arm64-v8a" }
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

The type key (`cmake`, `meson`, `harmony`, `typescript`) is the only required field. Its
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

**Harmony type_config fields**:

| Field | Description |
|-------|-------------|
| `configurations` | Dict of config_name → config overrides |
| `cmake_env` | Dict of env_var → value, passed to hvigor's cmake as environment variables. Supports `${workspace_root}` expansion. |

**Explicit profile fields**:

| Field | Description |
|-------|-------------|
| `configuration_set` | Name of a configuration set to derive mappings from |
| `kit_id` | Tool key to use (e.g., `"ninja-ohos-clang"`) |

---

## 2. Three-File Model

### 2.1 loomworks.json — Published Snapshot (optional)

Shared configuration. Contains items the user has explicitly **published**.
Written only when the user saves from the status page (`:w`).

- **Optional** — the system functions without this file. A workspace can
  exist with user.json alone. loomworks.json is created only when the user
  explicitly publishes (`:w`).
- Committed or gitignored (user's choice).
- Changes from outside (branch switch, manual edit) are detected via file
  watcher and hot-reloaded.
- Paths are relative to workspace root.
- Absolute paths are **forbidden** (breaks portability).
- `${ENV_VAR}` expansion for toolchain paths.

### 2.2 .nvim/loomworks.user.json — Working Copy

The primary working file. All UI mutations land here. Contains the full
working state: every item the user has interacted with, plus metadata
(active profile, profiles, published flags).

```json
{
  "_meta": { "version": 2 },
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "profiles": { ... },
  "default_target": { ... },
  "device": { ... }
}
```

The `device` field maps profile keys to device serial strings:
```json
"device": {
    "Debug:ohos-sdk-5.0": "FMR0225108000951"
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
- **Profiles**: `_published` defaults to `false`. Profiles are personal by
  default. User explicitly opts in to sharing via `P`.

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
- **External build directories**: Modules using external build systems
  (e.g., harmony/hvigor) may have build directories outside `.nvim/build/`.
  The cache key for these is their absolute path (no `.nvim/` prefix to
  strip). `absolute_build_dir()` detects absolute paths and returns them
  unchanged. Deletion safety requires the path to be under workspace root.
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
UI.

**Process**:
1. Receive structured data: set_name and optional tool_entry (tool_key,
   tool_data, tool_label, tool_mod_type)
2. Look up set_name in `configuration_sets` → mappings
3. For each project in the mappings:
   - Compute config_key (variant + tool_key for keyed modules)
   - Create skeleton cache entry if absent
4. Write profile entry (with `configuration_set` and tool fields) to
   `cache.profiles`
5. Save user.json, trigger remerge

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
2. Orphaned configs are never auto-adopted into profiles
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
2. If referenced by any profile → disposition = `reset`
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

## 6. UI

User-facing UI behavior — the status page, highlight groups, and
the winbar/statusline component — lives in
[`spec/ui.md`](spec/ui.md). Cross-refs from elsewhere in core to
specific UI behavior should target sections within that file.

---

## 7. Events

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
| `devices_changed`      | `Device[]` | Device scan completed |

Events pass data directly to listeners — no need to re-query, no race
conditions.

---

## 8. Module Interface

A module is a handler for a project type. Modules implement a standard
interface that the core system calls for project discovery, task generation,
and staleness detection.

### 8.1 Required methods

**`detect(abs_path) → { marker }|nil`**

Detect whether a directory looks like a project of this module type. `abs_path`
is the absolute directory path. Returns `{ marker = "filename" }` identifying
the marker file that triggered detection, or `nil` if not detected.

Used by the project browser for auto-detection. Lightweight check — no
subprocess spawning, no deep file parsing. See per-module specs in
[`spec/modules/`](spec/modules/) for the marker file each module uses.

**`validate(path, config) → { valid, warnings[] }`**

Check whether the project directory is valid for this module type. `path` is
the absolute project directory. `config` is the type_config from the
workspace config (the value of the module's type key, e.g. the dict under
`"cmake"` or `"harmony"`).

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

Non-keyed modules may call the callback immediately with a single
entry containing empty `tool_data`.

Modules that spawn subprocesses (e.g., compiler detection) must use
non-blocking APIs (libuv spawn or jobstart) and chain results
sequentially to avoid flooding the OS with processes.

### 8.2 Tool identity methods

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
requiring separate cache entries. Used by merge to construct config keys
without requiring tool detection to complete first. See per-module specs
for which modules are keyed.

### 8.3 Variant mapping

**`map_variant(variant_type, available_configs) → string|nil`**

Map a semantic variant type to a configuration name from the project's
available configurations. Used by `generate_default_config_sets()` to
compute cross-project configuration sets automatically.

Variant types (defined by core, queried in order):
- `"debug"` — development/debug build
- `"release"` — optimized production build
- `"release_debug"` — optimized with debug info (optional)

Each module knows its own naming conventions. See the per-module specs
in [`spec/modules/`](spec/modules/) for the exact mapping each one
uses.

**Single-config fallback**: If only one configuration exists, return it for
any variant type (the project builds the same way regardless).

Returns `nil` when no matching configuration exists and the project has
multiple configurations.

### 8.4 Optional methods

**`progress_parser(project?, active_config?) → string|nil`**

Return the name of a registered progress parser (e.g., `"ninja"`), or `nil`
if the module has no progress tracking. Parameters are optional — modules
may ignore them or use them to select a parser based on context.

**`get_options(build_dir, config?) → (OptionGroup|Option)[]|nil`** *(optional)*

Return the user-facing build options as a tree of groups and options.
`OptionGroup` has `label` and `children` (nested groups or options).
`Option` has `key`, `value`, `value_type` (`"bool"`, `"string"`, `"path"`,
`"filepath"`), optional `helpstring`, and optional `choices`. `config` is
the module's type_config from the workspace config.

Only options meaningful to the user are included — internal/computed
variables are excluded. Returns nil if the project is not configured or
has no options. Called on demand, not cached.

Modules may support module-specific grouping or filtering of options via
their `type_config`. See per-module specs for details.

**`resolve_build_dir(project_name, config_name, config_info, workspace_root, tool_data) → string`** *(optional)*

Return the absolute path of the build directory for a given project
configuration. Modules that use external build systems return paths
outside `.nvim/build/` managed by the external tool. The path must be
under `workspace_root` for deletion safety. If not implemented, the
core uses the default formula:
`{workspace_root}/.nvim/build/{project}/{config}`.

**`invalidate_tools()`** *(optional)*

Clear any cached tool-detection state the module holds. Called by core
before `rescan_tools()` runs, so the module's next `detect_tools_async`
starts from a clean slate. Keeps core free of module-specific cache
requires.

**`editable_type_config_fields() → EditableFieldDef[]`** *(optional)*

Declare which fields of the module's `type_config` the core UI should
render as editable. Each entry describes one field; the UI iterates the
list, reads the current value from `project.type_config[field.name]`,
and renders an appropriate editor based on `field.kind`.

Field def shape:

| Field | Purpose |
|-------|---------|
| `name` | Key in `type_config` |
| `label` | Section header shown in the UI |
| `kind` | Editor type. Currently supported: `"env_dict"` (string→string dict of name/value pairs) |

The core UI uses `Project:save_type_config_field(name, value)` to persist
edits. Modules need not implement this method; when absent, no generic
type_config editor is rendered. See per-module specs for the fields each
module exposes.

**`lsp_configs(project) → LspConfigEntry[]`** *(optional)*

Return LSP server configurations for this project. Each entry describes
one LSP server the module wants attached to buffers under this project.
Entries are **opaque to core** — only the server-specific integration
(e.g. `lua/loomworks/integrations/lsp/clangd.lua`) parses the fields.

Entry shape (core-defined fields):

| Field | Purpose |
|-------|---------|
| `server` | Server name — selects the integration |
| `root_dir` | Absolute path used for root_dir matching and client scoping |
| _…per-server_ | Each integration documents its own additional fields. See [`spec/integrations/lsp/`](spec/integrations/lsp/). |

Modules with no LSP needs return `{}` (or omit the method). The module
may traverse core domain objects (Project, ConfigUnit) to resolve
references.

Core never reads entry contents beyond `server` and `root_dir` — all
other interpretation is delegated to the per-server integration.

**`parse_targets(ctx) → targets?`** *(optional)*

Discover build targets for the project. Returns a dict of
`target_name → { type, dependencies?, artifact? }` for project-owned
targets, or `nil` if no data is available. Called by core after a
successful configure task or during startup scan.

`ctx` is a table with:
- `build_dir` — absolute build directory (for modules that read build
  output)
- `project_path` — absolute project root path (for modules that read
  source files directly)
- `config_name` — configuration variant name (for multi-config
  generators to select the correct reply)

Each module uses only the fields it needs. An async companion
`parse_targets_async(ctx, callback)` may be provided for discovery that
involves I/O.

Only project-owned build targets are included (executables and libraries).
Imported, alias, and utility targets are excluded. Dependencies list only
project-owned targets that this target links against.

### 8.5 Module implementations

Each module that ships with loomworks documents its implementation of
this contract in its own spec file:

- [`spec/modules/cmake.md`](spec/modules/cmake.md) — cmake projects
  (CMakePresets, file-api target discovery, ctest/gtest integration)
- [`spec/modules/harmony.md`](spec/modules/harmony.md) — HarmonyOS /
  OpenHarmony projects (build-profile.json5 configurations, hvigor
  build dirs, hdc device interface)
- [`spec/modules/meson.md`](spec/modules/meson.md) — meson projects
  (introspect-driven discovery, per-compiler kits)
- [`spec/modules/typescript.md`](spec/modules/typescript.md) — v1 stub
  (project detection only, no build tasks)

Third-party modules follow the same shape: implement the contract above
and document the implementation alongside.

### 8.6 Per-target builds

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
   `build_target_task()`.

**Module interface**: `build_target_task(project_ctx, target_id)` returns
an overseer task definition for building a single target. Falls back to
full build if the module doesn't implement it.

### 8.7 Target launching

Each profile can have a default launch target — a configuration that
defines how to run the project after building. Two types:

**Module targets** (executables discovered by the module's
`parse_targets`): `Target:launch()` resolves the artifact path from
the build directory and runs it via overseer.

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

### 8.8 Deploy Steps

Deploy steps ensure build artifacts from one config unit are copied to the
correct location before a launch target runs. They guarantee that the
launched process sees up-to-date files regardless of which configuration was
most recently built.

**Definition**: A deploy step is a declarative intent — "ensure artifact X
from source config unit Y is at destination Z, up to date." Deploy steps are
defined at two levels:

- **Project-level** (`projects.<name>.deploy`): applies to every launch,
  build, and device target for this project.
- **Launch-level** (`projects.<name>.launch.<launch_name>.deploy`):
  applies only to this specific launch config.

Each step can also run in one of two **phases** via a `pre_build` source
flag: before the target is built (`pre_build: true`) or after
(default, post-build). Pre-build steps let one project deposit files
into another project's source tree so they are picked up by its build.

#### 8.8.1 Syntax

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
| `pre_build` | no | Default `false`. If `true`, this step runs **before** the launch target is built, so the deployed file is an input to the target's build (e.g., bundling a `.so` into a HAP). If `false`, runs after build. |

**Duplicate destination keys**: JSON does not allow duplicate keys in an
object. If `loomworks.json` contains two entries with the same destination
key, the JSON parser silently keeps only the last one. Use the array
source format to copy multiple files to the same directory.

**Project + launch merge rule**: When the same destination appears at
both project level and launch level:

- **Directory destinations** (trailing `/`): sources from both levels are
  **concatenated** (union). Both sets of files are copied.
- **File destinations** (no trailing `/`): launch-level **overrides**
  project-level wholesale. Only the launch-level source is used.

Rationale: directories are collection points where the intent is usually
to add more files; file destinations are specific override points where
only one file can end up at that path.

Source fields use **no variable expansion** — `target` is a cmake target
name resolved via the module, `path` is a literal relative path from the
source config unit's build directory.

#### 8.8.2 Source resolution

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

#### 8.8.3 Freshness tracking

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

#### 8.8.4 Launch flow with deploy

The launch flow (section 9.7) is extended with both deploy phases:

1. Get active profile's default target (LaunchTarget)
2. Collect deploy sources from both project-level and launch-level
   `deploy` dicts; include unique source projects in the dependency set
3. **Build dependencies** (explicit `depends_on` + deploy source projects)
4. **Execute pre-build deploy steps** (`pre_build: true` sources).
   These run after deps are built so their outputs are up to date, but
   before the launch target builds so hvigor/cmake sees the copied files
   as inputs.
5. **Build self** (if buildable)
6. **Execute post-build deploy steps** (`pre_build: false`, default).
   These land artifacts near the launch binary (e.g., `.node` files,
   DLLs) without affecting the build.
7. Launch (or device install + launch)
8. Open overseer window for launch output

Any failure in any step **blocks the chain** and notifies the user with
a specific error. Deploy steps within a phase execute sequentially.

#### 8.8.5 Cleanup on deletion/clean

When a config unit is deleted or cleaned (sections 4.6, 4.7):

1. Scan deploy records for entries where `source_build_dir` matches the
   affected config unit's build dir id
2. Delete the destination files (if they exist on disk)
3. Remove the deploy records from cache
4. Save cache

This ensures deployed artifacts do not outlive their source build
directories.

#### 8.8.6 Design for extension

The deploy system is designed for further extension:

**Cascade levels**: Project-level and launch-level deploy are
implemented with the merge rules described in §8.8.1. A configuration
level is reserved but not yet implemented:

```
Project.deploy          → applies to all configs/launches of this project      (implemented)
  Configuration.deploy  → overrides project-level for this configuration       (deferred)
    Launch.deploy       → overrides config-level for this launch               (implemented)
```

When configuration-level deploy is added, the same merge rules apply:
directory destinations union, file destinations override. A `null`
value at a more specific level to suppress a parent-level deploy step
is also deferred.

**Action types**: The `deploy` dict currently implies a "copy" action.
Future actions (symlink, script execution) could be specified via an
explicit action field in the source descriptor.

**user.json deploy**: Deploy steps live in user.json as part of the
working copy. Published deploy steps are written to loomworks.json on `:w`.

### 8.9 Test Integration

Loomworks provides test discovery, execution, and result reporting through
a neotest adapter. ConfigUnit is the test interface — callers never interact
with TestUnit or framework helpers directly.

#### 8.9.1 Architecture

```
ConfigUnit
├── test_units() → TestUnit[]     (created lazily by module)
├── discover_tests()              (delegates to TestUnits)
├── run_test(test_id)             (finds owning TestUnit, delegates)
└── run_tests()                   (delegates to all TestUnits)

TestUnit (interface — test_unit.lua)
├── per-module TestUnits (see spec/modules/<mod>.md)
└── shared framework helpers (e.g. gtest)
```

The `TestUnit` interface is the seam: each module that supports tests
implements one or more TestUnit subclasses (factory'd via the module's
`create_test_unit(config_unit)`). Framework-specific helpers (e.g.,
gtest binary probing) live alongside the module that introduced the
need. See per-module specs in [`spec/modules/`](spec/modules/) for
which TestUnits each module ships.

#### 8.9.2 TestUnit interface

TestUnit (`test_unit.lua`) is the base interface for test sources within
a ConfigUnit. Each TestUnit represents one way to discover and run tests.
A ConfigUnit may have multiple TestUnits (though typically one).

**Required methods**:

**`discover() → TestEntry[]|nil`**

Discover tests synchronously. Returns a flat list of test entries or nil.
Includes framework detection and source location mapping.

**`discover_async(callback)`**

Async version. Calls `callback(entries)` when done. Used during
background cache population.

**`test_command(test_id, opts?) → RunSpec|nil`**

Construct the command to run a specific test. Returns
`{ cmd, env, cwd, output_path }` or nil.

**`test_command_all(opts?) → RunSpec|nil`**

Construct the command to run all tests. `opts.filter` for name filtering.

**`parse_results(output_path) → TestResult[]|nil`**

Parse structured test output into results.

**`invalidate()`**

Clear all cached data (entries, framework detection). Called after
build/configure completes.

**`entries() → TestEntry[]|nil`**

Return cached entries without triggering discovery.

#### 8.9.3 ConfigUnit test interface

ConfigUnit delegates all test operations to its TestUnit instances.
TestUnits are created lazily on first `test_units()` or `discover_tests()`
call via the module's `create_test_unit(config_unit)` factory.

**`config_unit:test_units() → TestUnit[]`**

Returns the array of TestUnits the owning module created (empty if the
module does not support tests).

**`config_unit:discover_tests() → TestTree|nil`**

Returns merged test entries from all TestUnits. Cached on `_test_tree`;
invalidated after successful build or configure.

**`config_unit:discover_tests_async(callback)`**

Async version for background population.

**`config_unit:invalidate_tests()`**

Clears `_test_tree`, `_test_results`, and `_test_units`. Called by
`Workspace:record_task_result()` after successful build or configure.

**`config_unit:run_test(test_id, opts?) → Future`**

Prerequisite chain: `run_configuration_action("build")` → launch test
via overseer. Finds the owning TestUnit, delegates command construction.

**`config_unit:run_tests(opts?) → Future`**

Same chain, runs all tests.

**TestTree entry format**:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier (e.g., `"test:Suite.Case"`, `"target:Runner"`) |
| `name` | string | Human-readable display name |
| `file` | string\|nil | Absolute source file path (canonical, for neotest navigation) |
| `line` | number\|nil | 1-based line number in source |
| `parent` | string\|nil | Parent entry id (for tree nesting) |
| `runnable` | boolean | Whether this entry can be executed directly |
| `framework` | string\|nil | Detected framework (`"gtest"`, nil for opaque) |
| `executable` | string\|nil | Path to test binary |
| `status` | string\|nil | Last result: `"passed"`, `"failed"`, `"skipped"`, `"errored"` |
| `message` | string\|nil | Last failure message |
| `duration` | number\|nil | Last duration in milliseconds |

#### 8.9.4 Neotest adapter

The loomworks neotest adapter (`neotest/init.lua`) bridges ConfigUnit's
test interface to neotest's adapter protocol. No framework-specific code
in the adapter — it works through TestUnit/TestTree only.

**File discovery model**: Neotest is file-centric — it discovers tests
by scanning the filesystem for test files. The adapter uses cached test
data to guide neotest's scanning:

- `is_test_file(path)`: checks the cached test file set (files with
  matched test entries). Falls back to a conservative filename pattern
  when cache is empty.
- `filter_dir(name, rel_path, root)`: checks the cached test directory
  set (directories that lead to test files). Returns false when cache is
  empty — neotest shows nothing until async discovery completes.
- `discover_positions(path)`: for each test file, returns entries from
  the cached test tree matching that file. All positions use the file
  path neotest passed (preserving its format for key matching).

**Cache population**: On module load, `setup_events()` registers
listeners for `workspace_changed` and `active_set_changed`. Sync
discovery runs during `require()` if the workspace is already loaded
(ensures cache is ready before neotest's first scan). Async discovery
runs in background otherwise, with `neotest.setup_project()` called
after completion to trigger re-scan.

**Position tree construction**: `build_neotest_tree()` creates a neotest
Tree from test entries. Each test position uses the file path for
`path` (enabling gutter marks and nearest-test), with `range` set to
the real source line when available or synthetic line numbers otherwise.

**Windows path handling**: All adapter methods use `pcall` wrapping
(neotest calls them in nio coroutine context where unhandled errors cause
permanent hangs). Paths use `to_native()` for backslash conversion and
`norm()` for forward-slash comparison. No `vim.fn` calls (these deadlock
in nio context).

**Execution** (`build_spec`): Finds the owning TestUnit via ConfigUnit
and asks it for the run command. Checks ConfigUnit state and warns if
the project needs configuring.

**Results** (`results`): Parses JUnit XML via TestUnit, maps results to
neotest positions by matching test IDs. Assigns overall pass/fail to
unmatched nodes.

#### 8.9.5 Prerequisite chain

Test execution reuses the same cascading pattern as builds. ConfigUnit
owns the chain — the caller requests the test and receives a Future:

1. **Configure if needed**: same as section 5.2.
2. **Build if needed**: build after successful configure.
3. **Run test**: after prerequisites complete, run via TestUnit.

Failure at any step stops the chain. Build directory operation queue
(section 5.3) applies — test runs acquire a shared lock.

#### 8.9.6 Debug integration

Debug integration uses `debug.lua` as the single gateway to nvim-dap.
When nvim-dap is not installed, all debug paths silently fall back to
their non-debug equivalents (launch via overseer, test run via overseer).

**Launch target debugging.** `LaunchTarget:debug()` mirrors `launch()`:
same build → deploy chain, but the final step calls `debug.run(spec)`
instead of `overseer.launch_run_task()`. Both command-type and module
target paths are supported. The DAP adapter is resolved per language
from `user.json` `debug.adapters` mapping, with per-language fallback
defaults provided by the integrations.

**Test debugging.** `loomtest.debug(test_id)` mirrors `loomtest.run()`:
same resolution logic (test/suite/target), same build-before-run via
`ensure_built()`, but dispatches to `runner.debug()` which calls
`debug.run()` with the test executable, gtest filter args, and
environment. On session termination, a per-session DAP listener parses
the gtest XML output and applies results to the test tree (signs,
inline annotations, explorer).

**debug.run(spec, callbacks)** constructs a DAP launch config from:
- `program` — executable path
- `args` — command arguments
- `cwd` — working directory
- `env` — environment variables
- `adapter` — DAP adapter type (resolved by caller)
- `extra` — adapter-specific fields merged into the DAP config

The exact request shape per adapter (e.g., whether `program`/`args`
are passed through unchanged or rewritten as `runtimeExecutable` +
`program` + `args` for JS-style adapters) is adapter-specific. See
[`spec/integrations/debug/`](spec/integrations/debug/) for the per-adapter
contracts.

Before launching, `debug.run()` checks that the adapter is registered
in nvim-dap. If not, it shows a notification with Mason install hint
and returns false (falls back to non-debug launch).

Optional `callbacks.on_terminated` registers a one-shot listener on the
DAP session that fires on `event_terminated` or `event_exited` and
auto-removes itself.

**Adapter configuration** in `user.json` is keyed by language:
```json
{
  "debug": {
    "adapters": {
      "c++": "codelldb",
      "typescript": "pwa-node"
    }
  }
}
```

If omitted, the per-integration defaults apply.

**Adapter selection UI.** The status page shows a Debug Adapters
section listing the current adapter per language. Enter on an item
opens a picker with known adapters showing installed/default/current
status. Selection persists to `user.json` via
`Workspace:set_debug_adapter(language, adapter)`. Known adapters per
language are reported by the integrations themselves.

**Language-based adapter resolution.** Adapters are resolved per
language, not per module type. Modules declare their supported
languages via `M.languages`. The workspace-level `debug.adapters`
mapping uses language keys.

**Multi-adapter debugging.** A launch config can specify a `debug`
array of language strings to attach multiple debuggers to the same
process:
```json
{
  "launch": {
    "app": {
      "command": "node",
      "args": ["app.js"],
      "debug": ["typescript", "c++"]
    }
  }
}
```

First entry launches the process, remaining entries attach to the
same PID (captured from `runInTerminal` response). Each language
resolves to its configured adapter. The launch editor UI supports
adding, removing, and reordering debug languages.

Format: each entry is either a string (language name) or an object
(`{ "language": "c++", ... }`) for future extensibility.

**Session tracking.** `session_tracker.lua` manages the lifecycle of
all active runs (overseer launches and dap debug sessions). When
starting a new run while one is active, a confirmation dialog asks
whether to terminate the existing session. Fidget progress spans the
full debug startup: building → deploying → starting debugger →
debugging (on `event_initialized`). Stop terminates the full dap
session hierarchy (`hierarchy = true`), ensuring the debuggee process
is killed alongside the adapter. Tracked runs auto-clean on dap
session end via per-session listeners.

**Default keymaps** registered by `setup()` (opt-out with `keys = false`):

| Key | Action |
|-----|--------|
| `<F5>` / `<leader>wr` | Debug target (build → deploy → dap) |
| `<leader>wR` | Launch target without debugger |
| `<leader>tt` | Debug nearest test |
| `<leader>tT` | Run nearest test |
| `<leader>tf` | Debug file tests |
| `<leader>tF` | Run file tests |
| `d` (loomtest explorer) | Debug selected test |
| `r` (loomtest explorer) | Run selected test |

**Debug adapter implementations.** Each adapter loomworks knows about
documents its language coverage, request shape, and any
adapter-specific transforms in its own spec file:

- [`spec/integrations/debug/codelldb.md`](spec/integrations/debug/codelldb.md)
  — native debugger (default for `c++`).
- [`spec/integrations/debug/cppdbg.md`](spec/integrations/debug/cppdbg.md)
  — alternative native debugger (Microsoft cpptools).
- [`spec/integrations/debug/pwa-node.md`](spec/integrations/debug/pwa-node.md)
  — Node.js / TypeScript (default for `typescript`).

A pluggable backend registry mirroring the LSP design is on the
BACKLOG; today `debug.lua` holds the dispatcher and adapter logic
together.

---

## 9. LSP Integration

LSP integration is split between a thin core dispatch layer
(`lua/loomworks/lsp.lua`) and per-server integration files
(`lua/loomworks/integrations/lsp/<server>.lua`). Core is module-agnostic:
modules emit opaque `lsp_configs()` entries keyed by `server` name, and
core routes them to the matching integration. Integrations are discovered
from every runtime path, so drop-in integrations (either in the user's
own config or in a sibling plugin) register automatically alongside the
built-in ones.

### 9.1 Module interface (§8.4 `lsp_configs`)

Modules produce entries shaped as `{ server = "...", root_dir = ...,
<per-server fields>... }`. Core only inspects `server` to dispatch;
integrations parse the remaining fields. Modules may traverse core
domain objects (Project, ConfigUnit) to resolve cross-configuration
references inside themselves, so paths emitted in the entry are
fully resolved.

### 9.2 Dispatch layer (`lsp.lua`)

Responsibilities:
- **Discover and load integrations on startup.** `lsp.lua` scans every
  runtime path for `lua/loomworks/integrations/lsp/*.lua` via
  `vim.api.nvim_get_runtime_file` and requires each file. Each
  integration self-registers by calling `require("loomworks.lsp").register(server, M)`.
  This means integrations can live in the plugin itself, in the user's
  own `~/.config/nvim/lua/loomworks/integrations/lsp/`, or in another
  plugin on the runtime path — all three are discovered automatically.
- **Expose generic factories** — `loomworks.lsp.cmd(server, base_cmd)`
  and `loomworks.lsp.root_dir(server, fallback)` delegate to the
  registered integration. Server-specific aliases (e.g.,
  `clangd_cmd`/`clangd_root_dir`) are kept as thin back-compat wrappers
  in the relevant integration file.
- **Wire integration listeners.** On startup, `lsp.lua` subscribes once
  to `active_set_changed` and `workspace_changed` and fans out to every
  integration's `on_active_set_changed` / `on_workspace_changed` hook.
  Integrations don't register listeners themselves.
- **Provide `get_status()`** iterating all projects, calling each
  module's `lsp_configs()`, matching LSP clients by root_dir per server,
  and delegating per-server status fields to each integration's
  `status_extras(entry)` callback.

Core never references specific LSP server names. Adding a new server
means adding an integration file — no changes to `lsp.lua`.

### 9.3 Integration contract

Each `integrations/lsp/<server>.lua` returns a table with these fields
(all but `server` optional):

| Field | Purpose |
|-------|---------|
| `server` | Server name — must match `entry.server` |
| `build_config(user_cfg) → table` | Returns the full `vim.lsp.config` payload. Called by `setup_servers()` — merges user overrides with integration defaults, installs function-based `cmd` and `root_dir` |
| `default_enable` | `true` if this integration should be enabled when the user calls `setup({})` with no explicit `lsp` opt-in |
| `cmd_factory(base_cmd) → fn` | Builds a `cmd` function — used by `build_config` and exposed for users who prefer lspconfig |
| `root_dir_factory(fallback) → fn` | Builds a `root_dir` function — same pattern |
| `get_resolved_cmd(root_dir) → string[]\|nil` | Last-resolved cmd args (status display) |
| `status_extras(entry) → table` | Per-server fields merged into `extra` on the status page |
| `on_active_set_changed()` | Called on profile/active-set change |
| `on_workspace_changed()` | Called on workspace swap / first load |

The integration's module body calls
`require("loomworks.lsp").register(name, M)` as its last action, then
returns `M`. Discovery handles the rest.

### 9.4 Server installation (`setup_servers`)

`loomworks.setup({ lsp = ... })` controls which servers loomworks
installs via `vim.lsp.config` + `vim.lsp.enable`:

| `opts.lsp` | Behavior |
|------------|----------|
| unset or `{}` | Install every integration with `default_enable = true` using its own defaults; apply default buffer excludes |
| `false` | Skip entirely — no `vim.lsp.config` calls; integrations still wrap clients that other code started |
| `{ <server> = {...} }` | Install `<server>`; user fields (cmd, on_attach, capabilities, settings, …) merge with integration defaults |
| `{ <server> = true }` | Install `<server>` with integration defaults |
| `{ <server> = false }` | Skip `<server>` specifically |
| `{ excludes = ... }` | Override default buffer excludes. See below |

**Buffer excludes** apply uniformly to every integration loomworks
manages — no language server handles `diffview://`, `fugitive://`,
`quickfix`, etc. well, so loomworks suppresses attachment to those
buffers before `root_dir` resolution and detaches any client that
attaches via filetype match (via an `LspAttach` autocmd). Defaults:

| Field | Default |
|-------|---------|
| `bufname_patterns` | `{ "^diffview://", "^fugitive://", "^octo://", "^gitsigns://", "^term://" }` |
| `buftypes` | `{ "help", "quickfix", "prompt", "nofile", "terminal" }` |

User override forms for `opts.lsp.excludes`:

| Form | Behavior |
|------|----------|
| unset (no `excludes` key) | Use defaults |
| `false` | Disable exclusion entirely |
| `{ bufname_patterns = {...}, buftypes = {...} }` | Replace defaults wholesale |
| `function(defaults) return ... end` | Receive a fresh copy of defaults, return the modified excludes (extend pattern) |

`loomworks.lsp.default_excludes()` returns a fresh deep copy of the
defaults so users can build extensions without touching internal state.
`loomworks.lsp.excluded(bufnr)` returns whether a given buffer is
excluded under the currently resolved excludes; integrations call this
from their `root_dir_factory` so excluded buffers never get matched to a
workspace project.

The integration's `build_config(user_cfg)` always wraps `cmd` and
`root_dir` with loomworks functions — the user's `cmd` becomes the
base/fallback passed into `cmd_factory`. This lets a single nvim session
transparently use a workspace-resolved server inside a project and the
user's stock server outside any project.

Footgun: if the user calls `vim.lsp.config("<server>", { cmd = ... })`
*after* `loomworks.setup`, their static cmd replaces loomworks' wrapping
function. On `VimEnter`, loomworks compares the installed cmd against
the currently-registered one; any mismatch triggers a single warning
pointing the user at the fix.

### 9.5 LSP integration implementations

Each integration shipped with loomworks documents its server-specific
fields, lifecycle, and status display in its own spec file:

- [`spec/integrations/lsp/clangd.md`](spec/integrations/lsp/clangd.md)
  — clangd (C/C++/Objective-C/CUDA), with SDK-aware binary resolution
  and per-buffer `compile_commands.json` routing.

Third-party integrations follow the same shape: implement the
contract above and document the per-server fields alongside.

---

## 10. SDK Provider Contract

An SDK is a resolved platform installation (e.g., a HarmonyOS / OHOS
SDK shipped inside DevEco Studio, an Android NDK, an embedded vendor
toolchain) that supplies tools to one or more modules. SDK providers
are pluggable: each provider lives at `lua/loomworks/sdks/<id>.lua`
and registers itself by being required from `lua/loomworks/sdks/init.lua`
or another runtime path file.

### 10.1 Provider interface

Each provider table exposes:

| Field | Purpose |
|-------|---------|
| `id` | Provider identity (e.g., `"ohos"`) — stable across versions |
| `display_name` | Human-readable name shown in pickers and status |
| `detect_all() → { path, version }[]` | Enumerate installations on the host. Pure detection — no validation, no domain object creation |
| `validate(path) → boolean` | Return whether a given path looks like a valid installation of this SDK type |
| `create_sdk(key, path, version) → SDK` | Construct a `loomworks.SDK` domain object from a validated installation |
| `query_capabilities(sdk, module_id) → table\|nil` | Return opaque capability data this SDK can offer to a given module, or `nil` if it has nothing for that module. `module_id == nil` returns the supported module ids array |

### 10.2 SDK domain object

`loomworks.SDK` (`lua/loomworks/sdk.lua`) wraps a resolved
installation. Fields:

| Field | Purpose |
|-------|---------|
| `key` | Identity key, persisted in user.json |
| `_type` | Provider id |
| `_version` | Detected version (or nil) |
| `_path` | Resolved installation path |
| `_resolved` | Whether the path is currently valid |
| `_intent` | `"shared"` / `"local"` for the publish/working-copy model |
| `_provider` | Back-reference to the provider table |

`SDK:query(module_id)` delegates to the provider's
`query_capabilities`. Returns `nil` when the SDK is unresolved or has
nothing for that module.

### 10.3 Capability shape

Capability data is **opaque to core** — only the requesting module
interprets it. A typical shape includes paths to platform tools
(compilers, packagers, simulator binaries), toolchain files,
architecture lists, and any flags that must be threaded into the
module's task generation. Each provider documents its shape per
module in its own spec file.

### 10.4 Profile-level pinning

A profile may pin an SDK by `key` in user.json. On reload, the SDK
is resolved by `key` against the workspace's known providers. If the
provider can no longer find the installation (e.g., DevEco moved or
uninstalled), the profile renders as incomplete with a rebase
action. No fallback guessing — incomplete profiles surface
explicitly.

When a profile has an SDK and a module asks for a tool, the resolver
consults the SDK first via `SDK:query(module_id)`. If the SDK
returns nil, the module falls through to host-tool detection. If
neither yields a tool and the profile has no explicit override, the
profile is incomplete.

### 10.5 SDK provider implementations

Each SDK provider documents its detection logic, validation rules,
and per-module capability shape in its own spec file:

- [`spec/sdks/ohos.md`](spec/sdks/ohos.md) — OpenHarmony /
  HarmonyOS via DevEco Studio.

Third-party providers follow the same shape: implement the contract
above and document the per-module capability shape alongside.

### 10.6 Future direction

Profile-level SDK selection is partially implemented and tracked in
BACKLOG.md. The current shape resolves SDK-supplied tools lazily on
each `Profile:tool_for(module)` call rather than persisting them in
the profile's `tools` dict. That keeps SDK refresh cheap (re-query on
load) at the cost of slightly more code in the access path.

---

## 11. Device Interface Contract

Devices are physical or emulated deployment targets (phones,
simulators, embedded boards). Any module may opt in to device
support; SDK providers may also expose devices in the future. Core
discovers device-capable modules and routes all device operations
through them — no per-module knowledge in core.

### 11.1 Device domain object

`loomworks.Device` (`lua/loomworks/device.lua`) is identified by
its `serial` string. Runtime-only — not persisted in cache or
user.json. Workspace owns `_devices` (serial → Device), populated on
demand via `Workspace:scan_devices()`.

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `serial` | string | Stable device identifier |
| `display_name` | string | Human-readable label |
| `state` | string | `"online"` / `"offline"` |
| `provider` | string | Module id that owns this device type |
| `properties` | table | Provider-specific extras |

### 11.2 Module opt-in

**Static property:**

| Property | Type | Description |
|----------|------|-------------|
| `has_devices` | `boolean` | `true` if this module's launch targets may require device deployment. Default `false`. |

**Methods** (all optional, only meaningful when `has_devices = true`):

**`list_devices(tool_data, callback)`** *(async)*

Enumerate connected devices. Calls `callback(devices)` where each
device is `{ serial, display_name, state, properties }`. The module
runs the device connector tool and parses its output.

**`device_targets(project_ctx, active_config) → table[]`**

Return device launch target descriptors for the active configuration.
Each descriptor has `{ id, label, requires_device }`. These appear in
the launch target picker alongside module targets and command-type
launches.

**`device_install(tool_data, device_serial, artifact_path) → { cmd, args, env? }`**

Return an overseer-compatible command spec for installing an
artifact onto a device. Does NOT execute the command — core runs it
via overseer. Always reinstalls (no freshness tracking).

**`device_launch(tool_data, device_serial, launch_info) → { cmd, args, env? }`**

Return a command spec to launch the installed app on a device.
`launch_info` is module-specific metadata produced by
`resolve_launch_info()`.

**`device_stop(tool_data, device_serial, bundle_name) → { cmd, args, env? }`**

Return a command spec that force-stops the app on the device.
Session tracker calls this from `stop()` when the active run is a
device launch so stop paths actually terminate the on-device process
rather than merely closing the local log stream.

**`device_pid(tool_data, device_serial, bundle_name) → { cmd, args, env? }`**

Return a command spec that, when run, prints the PID of a running
app on the device. Used by the session tracker for two purposes:
(1) initial PID discovery right after launch, and (2) periodic
polling to detect when the app has exited so the log stream can be
torn down automatically.

**`device_log(tool_data, device_serial, opts?) → { cmd, args, env? }`**

Return a command spec that streams device logs on stdout. `opts` is
an optional hint table (e.g., `opts.pid` for device-side filtering),
but the core `device_log` view does not rely on device-side filters
— it parses and filters the stream client-side. Modules may expose
whichever opts make sense.

**`device_log_clear(tool_data, device_serial) → { cmd, args, env? }`**

Optional. Return a command spec that flushes the device's log buffer.
Called by the session tracker right before starting a fresh stream so
the view doesn't mix in stale entries. Best-effort — errors here are
non-fatal.

**`resolve_artifact(project_ctx, active_config) → string|nil`**

Return the absolute path to the built artifact for device deployment.
Module-specific knowledge of where the build system places output.

**`resolve_launch_info(project_path, config_info, tool_data) → table|nil`**

Extract launch metadata from project files. Returns a table that is
passed to `device_launch()` as `launch_info`. Shape is
module-specific.

### 11.3 Launch flow with devices

The launch flow (§8.7) is extended when the target requires a device:

```
build → file-deploy → device-install → device-launch
```

1. **Build**: same as §8.7 — build dependencies, then build self.
2. **File-deploy**: same as §8.8 — copy artifacts between projects.
3. **Device check**: if `target:requires_device()` is false, proceed
   to normal launch/debug (existing path, unchanged). Otherwise:
4. **Device selection**: if the profile has no device serial, prompt
   with `vim.ui.select` populated from `list_devices()`. On
   selection, persist to profile.
5. **Device install**: call `resolve_artifact()` to find the artifact
   path, then `device_install()` to get the command spec. Execute via
   overseer as a tracked task. On failure, stop the chain with error.
6. **Device launch**: call `resolve_launch_info()` then
   `device_launch()`. Execute via overseer.
7. **Log stream** (best-effort):
   a. Resolve the launched app's PID via `device_pid()` (polled
      briefly — launch returns before the process is up).
   b. Clear the device log buffer via `device_log_clear()` (when the
      module provides it) so stale entries don't show up in the
      view.
   c. Start `device_log()` as a streaming task and hand its lines to
      the `loomworks.device_log` module, which parses each line,
      applies a session prefilter (PID OR proc-contains-bundle,
      union semantics), writes matches to a ring buffer, and renders
      filtered entries into a bottom-split scratch buffer.
   d. Start a periodic pidof poll (~3 s) on the session tracker.
      When the PID is gone for two consecutive polls the session
      tracker treats the app as exited, stops the log stream, and
      clears the active run.

   Failure at any step surfaces as a warning and does not fail the
   launch chain — the app is already running, we just can't follow
   its output this time.

Device targets always use launch mode in v1 (no device debug — see
BACKLOG.md "Native device debug").

### 11.4 LaunchTarget device support

LaunchTarget supports three target types:

| Descriptor field | Target type | Source |
|-----------------|-------------|--------|
| `target` | Module target (executable) | Module's `parse_targets` discovery |
| `launch` | Command launch | loomworks.json launch section |
| `device_target` | Device target | Module's `device_targets()` |

The `device_target` field stores the target ID.
`LaunchTarget:requires_device()` returns `true` when `_device_target`
is set.

The target picker collects from all three sources:
1. Launch configs from projects (`project.launch` dict)
2. Executable targets from `ConfigUnit.targets`
3. Device targets from modules (`module.device_targets()`)

### 11.5 Device interface implementations

Devices are typically implemented inside the module that knows the
relevant connector tool. See per-module specs:

- [`spec/modules/harmony.md`](spec/modules/harmony.md) §6 —
  HarmonyOS device interface via `hdc`.

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
| `"auto"` | Always load silently when a workspace file is found in cwd. Notify via `vim.notify`. |
| `"cached_only"` | Load silently if cache exists (`.nvim/loomworks.cache.json`). For uncached workspaces, notify but do not load. |
| `"prompt"` | Load silently if cache exists. For uncached workspaces, prompt the user for confirmation. |
| `false` | Never auto-load. Only manual `:LoomworksInit`. |

### 13.2 Triggers

Auto-load runs on:
1. **Plugin load** — checks cwd for workspace files
2. **`DirChanged` event** — checks new cwd for workspace files
3. **`SessionLoadPost` event** — re-checks cwd after session restore
4. **`User ResessionLoadPost` event** — re-checks cwd after resession.nvim
   session restore (safe to register even if resession is not installed)

All checks use **cwd only** — no parent directory walking. Use
`:LoomworksInit` for workspaces in parent or non-cwd directories.

**Detection order**: `loomworks.json` is checked first, then
`.nvim/loomworks.user.json`. Either file is sufficient to identify a
workspace root.

### 13.3 Behavior

When a trigger fires:
1. Check if `loomworks.json` or `.nvim/loomworks.user.json` exists in
   cwd (two `stat` calls).
2. If neither found → no-op.
3. If found and a workspace is already loaded at that root → no-op.
4. If found and a **different** workspace is already loaded → prompt
   "Switch workspace to {name}?" regardless of `auto_load` mode.
5. If found and no workspace is loaded:
   - `"auto"` → load and notify: "Loaded workspace: {name}"
   - `"cached_only"` + cache exists → load and notify
   - `"cached_only"` + no cache → notify: "Workspace found at {root}
     (run :LoomworksInit to load)"
   - `"prompt"` + cache exists → load and notify
   - `"prompt"` + no cache → prompt: "Workspace found at {root},
     load? (y/n)"
   - `false` → no-op

### 13.4 Loading side effects

Loading a workspace (whether via auto-load or `:LoomworksInit`) always:
- Reads `loomworks.json` (if it exists), `loomworks.cache.json`,
  `loomworks.user.json` asynchronously (non-blocking)
- When loomworks.json does not exist, the shared baseline is empty
  (no shared projects, config sets, or profiles)
- Creates `.nvim/loomworks.cache.json` if it does not exist
- Emits `workspace_changed` and `active_set_changed` events once
  initialized
- Starts asynchronous tool detection in the background
- Reports initialization and detection progress via fidget.nvim
  (if available)

### 13.5 Workspace initialization (`N`)

When no workspace exists (no loomworks.json, no user.json), the user
presses `N` on the status page to initialize:

1. Creates `.nvim/loomworks.user.json` with minimal content
   (`{ "_meta": { "version": 2 } }`)
2. Loads the workspace from user.json (empty shared baseline)
3. The status page shows an empty workspace with "Add project" sentinel

The user then follows the normal workflow: add projects via the project
browser, create configuration sets, create profiles.

No loomworks.json is created during initialization. It is created only
when the user explicitly publishes (`:w`).

### 13.6 Limitations

- **No file watching for workspace file creation**: If loomworks.json or
  user.json is created after Neovim starts and no `:cd` occurs, use
  `:LoomworksInit` manually.
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
