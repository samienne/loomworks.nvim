> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## Section 8 contents

- 8.0 API version
- 8.1 Required methods
- 8.2 Tool identity methods
- 8.3 Variant mapping
- 8.4 Optional methods
- 8.5 Module implementations
- 8.6 Per-target builds
- 8.7 Target launching
- 8.8 Deploy Steps (8.8.1-8.8.6)
- 8.9 Test Integration (8.9.1-8.9.6)

## 8. Module Interface

A module is a handler for a project type. Modules implement a standard
interface that the core system calls for project discovery, task generation,
and staleness detection.

### 8.0 API version

Every module table declares `M.api_version = N` matching the constant
in `lua/loomworks/api_versions.lua` (`module` field). The module
registry (`loomworks.modules.get(id)`) does a strict-equality check
at load time: a module whose declared version doesn't match core's
expectation is **refused**, with a one-shot `vim.notify` warning
naming the file, the declared version, and the expected version.

There is no backwards compatibility. A version bump in core means
every plugin that ships that module type must bump in lockstep.

**When to bump**: required field added, function signature changed,
return shape changed, capability flag semantics shifted. Adding a
new *optional* field with a sensible default does NOT require a
bump. The strict-equality enforcement makes false bumps painful
(every plugin breaks), so the rule naturally self-enforces.

A rejected module is treated the same as a missing one. Projects in
`loomworks.json` whose type maps to the rejected module are kept in
the in-memory model with their full `type_config` (configurations,
launch, variables, deploy), and round-trip cleanly through
`_serialize_config` / `_serialize_user`. The user can edit other
projects, publish, revert, or delete without losing data on the
rejected-type project. Build, launch, and configure operations
on it are simply unavailable until the version mismatch is
resolved.

The SDK provider registry uses the same mechanism with the `sdk`
field of `api_versions.lua`. LSP and debug integrations do not yet
have a versioned registry; they're wired more directly into core
today.

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
`"cmake"` or `"meson"`).

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

**Do not duplicate the build system's own change detection.** A module whose
generator re-runs configure automatically when its input files change — cmake
and meson under Ninja/Make regenerate on `CMakeLists.txt` / `meson.build`
edits — MUST NOT report file-mtime staleness from `inspect`. The generator
already handles it at build time, and stat-ing a top-level file is both
redundant and less accurate than the generator's own dependency tracking (it
misses subdirectory and `include()`d files, so it false-negatives on those
while false-positiving on the top-level one). Reserve `needs_refresh` for
meaningful changes the build system cannot detect on its own — e.g. a resolved
SDK/toolchain path that changed out from under a cached configure. Option-level
staleness (a configuration's `options`/`module_config` changed) is detected
separately by `ConfigUnit:is_stale()` and is not `inspect`'s responsibility.

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

**`validate_config_tool(configuration, tool) → ok, reason`** *(optional)*

Enforce that a tool the profile has selected is compatible with a
specific configuration's contract. Returns `ok=true` when compatible,
or `ok=false, reason=string` when the tool cannot honor the
configuration's claim. Modules that omit this method are permissive
(no check fires).

Called during profile-project sync, once per ProfileProject (i.e.
once per `(profile, configuration)` pair), against the tool that the
profile resolves for the configuration. The result is stored on the
ProfileProject as `_tool_compat_error` (nil when compatible) — *not*
on the ConfigUnit, because the same unit can be valid in one profile
and invalid in another. `ConfigUnit:tool_compat_error()` is a
convenience helper that looks up the *active* profile's
ProfileProject for the unit and returns its compat error.

When the active profile's PP has a compat error set, build, rebuild,
configure, clean, deploy, launch, and debug actions are blocked on
that unit; delete is allowed. The reason string is rendered in the
diagnostics section and surfaced on the failing config row's hover.
The profile-level status marker also swaps to ✗ when any of its PPs
has a compat error, so the problem is visible without expanding.

The check is intended for cross-module consistency invariants that
emerge from the profile's tool selection (e.g. a kit's platform/arch
claim must match the configuration's product). Modules whose tool
selection is binding by construction (the tool itself defines the
compiler) don't need this check.

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

**`runtime_path(ctx) → string[]?`** *(optional)*

Directories that must be on `PATH` to run the module's built executables
locally — typically the compiler's runtime bin directory (e.g. the gcc
toolchain bin holding `libstdc++`/`libgcc`/`libwinpthread`). Returns a list of
absolute directories, or `nil`. `ctx` carries `build_dir` and the
configuration's `tool_data`. This covers only the *toolchain* runtime; the
build tree's own shared-library output directories are added generically by
core (derived from `parse_targets`), so a module need not enumerate them.

### 8.5 Module implementations

Each module that ships with loomworks documents its implementation of
this contract in its own spec file:

- [`spec/modules/cmake.md`](spec/modules/cmake.md) — cmake projects
  (CMakePresets, file-api target discovery, ctest/gtest integration)
- [`spec/modules/meson.md`](spec/modules/meson.md) — meson projects
  (introspect-driven discovery, per-compiler kits)
- [`spec/modules/shell.md`](spec/modules/shell.md) — generic shell-command
  runner (self-managed builds: custom scripts, Make, vendor toolchains)
- [`spec/modules/typescript.md`](spec/modules/typescript.md) — v1 stub
  (project detection only, no build tasks)

Third-party modules follow the same shape: implement the contract above
and document the implementation alongside.

### 8.6 Per-target builds

Each profile can have a **default target** — a single executable target
that `build_target()` builds instead of the full project.

**Default target storage**:
- `loomworks.user.json`: `default_target = { "<profile_key>": { "project": "<key>", "target": "<id>", "working_dir"?: "<dir>" } }`
- Published profile definitions: `default_target = { "project": "<key>", "target": "<id>", "working_dir"?: "<dir>" }`
- User.json overrides published config.
- `working_dir` is optional; absent means the default (the project directory,
  §8.7). Absolute or workspace-root-relative, variable-expanded at launch.

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
the build directory and runs it. Before running, core composes a **run
environment** and prepends to `PATH`: (1) the build tree's shared-library and
module-library output directories — so a DLL-dependent executable finds its
siblings, the same directories the test runner uses — derived generically from
`parse_targets`; and (2) any `runtime_path()` directories the module supplies
for the toolchain runtime (§8.4). This applies on **Windows only**, where the
loader searches `PATH`; on Linux/macOS shared libraries are resolved through
the rpath the build system bakes into the build tree, so no environment setup
is needed. Directories are added in a deterministic (sorted) order so `PATH`
precedence is stable. Resolution (`Target:resolve_run_spec`) is shared with the
headless runner (§16.17); only the executor differs (overseer in the editor,
direct spawn headless).

A module target runs with its **working directory** set to the owning
project's directory (`workspace_root/<project.path>`) by default — the same
default as a command-type launch (below), so both launch kinds are consistent.
The default-target descriptor (§8.6) may carry an optional `working_dir` to
override this persistently; it is stored in the working copy and published like
the rest of the descriptor. A headless run (§16.17) may also override the
working directory for a single invocation. Precedence: per-invocation override
→ descriptor `working_dir` → project directory. An override may be absolute or
workspace-root-relative and is variable-expanded in the launch context.

**Command-type launches** (`launch` section in project config): Named launch
configurations per project with command, args, env, working_dir, deploy.

A launch configuration is either **command-type** — it carries a `command` —
or **target-backed** — it carries a `target` (a build target name/id) instead.
A target-backed launch runs that target's built artifact and inherits the
build-tree **run environment** (§8.7, the DLL-path setup), then layers the
config's `args`, `env` (over the run environment), and `working_dir` on top —
so a launch configuration for a built executable needs no hand-written path and
runs on Windows without a dev shell. The target reference resolves against the
configuration's parsed targets by name (or opaque id). Its default working
directory is the project directory, like a command-type launch.

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
   before the launch target builds so the downstream build sees the copied
   files as inputs.
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

Construct the command to run all tests as structured, per-test output (for the
editor UI): typically the test executable run under a framework harness that
emits a machine-readable results file. `opts.filter` for name filtering.
Returns `{ cmd, env, cwd, output_path }` or nil.

**`run_command_all(opts?) → { cmd, env?, cwd?, junit_out? }|nil`**

Construct the module's **native** "run all tests" command — the one whose
**process exit status is authoritative** (0 iff every test passed), streaming
human-readable output. This is the headless-runner seam (§16): a batch runner
executes it and reports its exit code, without discovery or result parsing.
Distinct from `test_command_all`, which targets structured UI results. Returns
nil when the module has no native batch runner. `opts.filter` for name
filtering; `opts.extra_args` appends caller-forwarded arguments (§16.16);
`opts.junit` requests JUnit XML at that path. `junit_out` reports where the run
actually writes JUnit — the requested path when the runner writes there
directly, or the runner's fixed location for the caller to copy across.

**`run_command_all_rebuilds() → boolean`**

Whether executing `run_command_all` rebuilds the unit's test targets first
(e.g. `meson test`, which builds test dependencies before running). A headless
test run (§16.16) skips its own separate build of such units, as it would be
redundant. Defaults **false** — the runner assumes an already-built tree
(e.g. `ctest`, which does not build). Configuration is still ensured either
way; this only governs the build.

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

