> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 1. Data Model

### 1.1 Workspace

A workspace is a directory containing a `loomworks.json` file. It is the
top-level organizational unit.

- One workspace is active at a time.
- The workspace root is the directory containing `loomworks.json`.
- When a tool discovers the root by searching upward from a starting
  directory, the search MUST NOT cross a git working-tree boundary: a
  directory holding a `.git` entry but no workspace marker ends the search
  with no root found. This keeps an invocation inside a fresh git worktree
  (whose own working copy does not exist yet) from binding to a parent
  checkout's workspace.
- Opening files outside the workspace does not change the active workspace.
- The workspace name defaults to the root directory name. It may be
  overridden by a `"name"` field in the working copy (`user.json`) or the
  published snapshot (`loomworks.json`); when both are present the working
  copy wins. As working-copy state (§2.4), a user-set name is stored in
  `user.json` and written to `loomworks.json` on publish.

### 1.2 Project

A project is a sub-component of a workspace with a type (cmake, meson,
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
  - `auto:` — project-file-derived configs emitted by modules whose
    configurations come from project metadata rather than fixed variants

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
strips entries with `:` in their name on load and emits a one-shot
warning, rather than failing the workspace open. (An older
serialization bug wrote auto-gen entries into loomworks.json; failing
to load would strand users with an unopenable workspace, so the
parser is permissive on the way in. Auto-gens are filtered out on
the way out — see §4.x serialization.) A user config's `inherits:`
reference, by contrast, uses the full canonical name —
`inherits: "variant:Debug"`, not bare `"Debug"`.

**Auto-gens are never persisted to loomworks.json or user.json.**
They regenerate from `module.info()` on every workspace load. Both
serialization paths skip any Configuration where `is_auto_gen()`
returns true: `_serialize_project_shared` and
`_serialize_config_internal` for loomworks.json,
`_serialize_user` for user.json. Persisting them in either file is
dead weight at best and a drift hazard if the module's emitted set
changes between sessions (e.g. a tsconfig.*.json file is added).

References (configuration_set mappings, inherits values, default
target pointers) store the full canonical name verbatim. Orphan
references — pointers at a name no live Configuration matches —
render in yellow with a ⚠ badge and a rename/rebase action, and
emit a one-shot `vim.notify` warning at load time so the issue
surfaces immediately rather than only on drill-down.

Loomworks configuration fields in the workspace config:
```
<type>.options                              — project-wide -D flags
<type>.configurations.<name>.inherits       — base config(s), string or array
<type>.configurations.<name>.options        — per-config -D flags
<type>.configurations.<name>.toolchain      — path to .cmake toolchain file
<type>.configurations.<name>.generator      — override generator
<type>.configurations.<name>.languages      — explicit language list override
                                              (string array; falls through to
                                              module.languages when omitted)
```

The `languages` field is the resolution axis that drives which tools
in a profile apply to this configuration. Default fallback is the
module's static `languages` declaration. User can override to add or
drop languages — e.g. when a `DISABLE_RUST_LIBRARIES` flag gates out
rust for a specific configuration, the user removes "rust" from that
configuration's `languages`. Empty explicit list means "no tools
needed" (rare).

**Inheritance model** (cmake): custom configs inherit from one or more bases.
Variant (CMAKE_BUILD_TYPE) is derived from the first base with a variant.
Options merge depth-first left-to-right: project-wide → bases → own
(later values override). A configuration with no variant — whether declared
on the configuration itself or inherited from a base — is an abstract mixin:
usable only as a base, never built directly. A profile whose configuration
set maps an abstract configuration MUST report itself unbuildable and name
the offending project/configuration; it MUST NOT fall through to a
module-chosen default build type, which would silently produce a build the
configuration never asked for. A
user-declared configuration is a source in its own right and MUST survive a
resync of module-emitted configurations even when it carries no fields yet;
an abstract mixin is exactly that case, and no module ever emits one.

**Derived values are not persisted.** A module propagates inherited values
(variant, and whatever else it derives from a base) onto the configuration so
the build path has something concrete, but those values MUST NOT be written to
the workspace files: a persisted copy of a base's value silently wins if the
base later changes, and it is indistinguishable from a value the user meant to
declare. Only what the configuration itself declares is serialized.

Consequently an **authoring host** (the command-line runner) makes a
configuration concrete by giving it a base to inherit, and does not offer the
variant as a settable field — the built-in `variant:*` configurations are the
single declared source of build types. Reading a directly-declared variant
remains supported, so hand-written and pre-existing files keep resolving.

**Default configurations**: always present, auto-generated from
`CMAKE_CONFIGURATION_TYPES` in CMakeLists.txt or standard cmake defaults
(Debug, Release, RelWithDebInfo, MinSizeRel). User entries in
the workspace config extend defaults (add options) rather than replace them.

### 1.3.1 Project Variables

Projects can declare user-defined variables with typed defaults. These
variables are expanded alongside built-in variables in launch configs
(command, args, env, working_dir), deploy destinations, and module
configure options (e.g. cmake `-D` cache-variable values).

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

**Compiler-specific overrides**: A configuration may additionally carry an
`overrides` block, keyed by compiler family (`clang`, `gcc`, `msvc`), whose
entries override variable values only when the active tool's compiler belongs
to that family. `overrides` participates in the configuration inheritance
chain exactly like `variables`, and every name it sets MUST be declared in the
project `variables` — a declaration may carry an empty `default`, so a variable
can exist purely to receive compiler-specific values.

```json
"cmake": {
    "configurations": {
        "Debug": {
            "variables": { "warn_flags": "-Werror" },
            "overrides": {
                "clang": { "warn_flags": "-Werror -Wno-unused-command-line-argument" }
            }
        }
    }
}
```

The compiler family is that of the resolved tool at configure time; a family
with no matching `overrides` entry at a given level falls through to that
level's compiler-agnostic `variables` value.

**Resolution order**: walk the configuration inheritance chain most-specific →
least; the first level that provides a value wins, and the project `default`
is the final fallback. *Within* a single level the value for a name is:
1. `overrides[active_family][name]`, when the active compiler matches a family
   that sets `name` at this level (compiler-match is the intra-level
   tiebreaker); otherwise
2. `variables[name]` (compiler-agnostic) at this level.

Chain position dominates compiler-specificity: a nearer configuration's plain
`variables` value shadows a farther configuration's `overrides` entry, so a
configuration that must keep a compiler-specific value re-declares it in its
own `overrides`.

**Value expansion**: Variable values can reference built-in variables
(`${workspace_root}`, `${build_dir}`, `${variant}`, `${config_set}`,
`${project_path}`) but NOT other user-defined variables. This prevents
circular references and keeps resolution simple. Cross-variable references
are deferred to a future version (with loop detection).

**Reserved names**: User variables cannot use built-in variable names
(`workspace_root`, `build_dir`, `variant`, `config_set`, `project_path`).
The system rejects declarations with reserved names at parse time.

**Override validation**: An `overrides` block is rejected at edit time if a
name is not declared in the project `variables` (mirroring the configuration
`variables` override rule), and its keys must be known compiler families
(`clang`, `gcc`, `msvc`) — an unknown family key surfaces as a workspace
diagnostic rather than being silently ignored. An option or launch value that
references an undeclared variable is likewise a diagnostic, never a silent
empty expansion.

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

A tool is a concrete buildable unit — a compiler chain, a kit derived from
an SDK, or a similar build orchestrator. Every Tool declares a `languages`
list (e.g. `["c", "c++"]` for ninja+clang, `["rust"]` for rust-nightly)
— the strings are opaque to core, drawn from each module's static
`languages` declaration unless the producer overrides per-tool. Tools
are looked up by **string key** from a module-owned registry
(`Module._tools`); the same kit identity can be registered to multiple
modules' registries when more than one module can consume it (the kit
appears under the same key in each registry, with different
module-specific `data`).

- **Keyed tools** (cmake, meson): cache key encodes the tool —
  `"Debug:ninja-gcc-12"`, `"Debug:gcc-14.2.0"`. Each generator+compiler
  combo produces distinct build output.
- **Non-keyed tools** (typescript shim): cache key = `"variant"`. The
  tool does not affect the cache key.

Tool detection runs asynchronously in the background:
- Automatically after workspace initialization completes
- On `rescan_tools()` / `L` key in the status page

Detection results are cached in memory for the session. Merge and
build operations work without detection results — cached profiles
store the tool keys they need, and the registry is rebuilt on load
from `detect_tools` + SDK enrichment.

Each module declares a static `has_keyed_tools` property (boolean)
so that config key construction works before detection completes.

### 1.5.1 Languages

Languages are first-class **string identifiers** that drive the
profile→project→tool resolution. Core treats them as opaque strings —
no normalization, no canonicalization. Each module declares a static
`languages` list (e.g. `cmake.languages = {"c++"}`, `meson.languages =
{"c", "c++"}`) that serves as the default for that module's
configurations and tools.

Languages live in three places:

| Owner | Field | Source |
|-------|-------|--------|
| Module | `module.languages` | Static, declared by the module |
| Tool | `Tool.languages` | Producer-supplied or falls through to module's |
| Configuration | `Configuration.languages` (optional) | User override; falls through to `module.languages` via `Configuration:effective_languages()` |

Resolution is **declarative**: a profile is invalid when any of its
configurations declares a language no tool in `profile._tool_keys`
provides. Auto-detection from build-system metadata (cmake file-api,
meson introspect) is a future refinement — a soft diagnostic, not
authoritative.

### 1.5.2 Version matching

A profile pins tools by key. A pinned key resolves to a registered tool by
**exact match first**, then by **dotted-version prefix**: a pin matches any
registered tool whose key extends the pinned version on a component
boundary — `ninja-clang-19` matches `ninja-clang-19.1.5`, and
`ninja-clang-19.1` matches `ninja-clang-19.1.9`. A fully-specified pin
(`ninja-clang-19.1.5`) matches only that exact version — it never relaxes.
When several tools match a prefix pin, the highest version wins; pin more
specifically to disambiguate.

Pinning at a coarse granularity (major version) makes a profile portable
across machines whose exact patch releases differ — the intended form for
shared profiles. The **resolved** tool is always the concrete full-version
one, and it — not the pin — determines the build directory and cache key
(§2.3), so build directories stay fully versioned and isolated.

### 1.6 Profile

A profile is a fully resolved buildable unit. Every profile stores its
own **mappings** (project_key → variant) directly, plus an **ordered
list of tool keys** (`profile.tools = ["key1", "key2"]`). Profiles
are what users activate, build, configure, and delete.

All profiles are **set-based** — they reference a configuration set and
derive their mappings from it on every remerge. Adding/removing projects
in the config automatically updates the profile.

**Toolchain shape**: a profile carries `tools` as a flat array of
string keys (same shape in user.json and loomworks.json). Order is
user-controlled — first-match-per-language wins during resolution.
Tool keys carry SDK provenance via the kit_id prefix
(e.g. `<sdk>-<platform>-<arch>`); there is no separate `sdk` field
on the profile.

Resolution is **language-keyed**:

- `Profile:tools_for(configuration)` walks `_tool_keys`, looks each key
  up in the configuration's project module's registry
  (`Module._tools`), and for each language in
  `configuration:effective_languages()` returns the first tool that
  provides it.
- `Profile:missing_languages_for(configuration)` reports the gap.
- A profile is **incomplete** when any of its (project, configuration)
  pairs has an unresolved language (the `is_valid` gate).

**Build dir naming**: when the effective tool set has more than one
entry, the build_dir segment is the sorted+joined tool keys
(`build/<project>/<key1+key2>/<variant>`). Single-tool segments are
identical to the legacy `build/<project>/<key>/<variant>` shape so
existing cache entries survive.

**Profile keys are opaque identifiers** — they exist solely for cache
persistence and display. They carry no semantic meaning and must never be
parsed, compared, or used to match profiles to other objects. All matching
uses object references or property-based comparison.

**Profile key format**: `<set_name>:<sorted-deduped-tool-keys>` joined
with `+`. Bare `<set_name>` when no tools (typescript-only profile).
Examples:

| Profile shape | Key |
|---------------|-----|
| Set-based, single tool | `debug:ninja-gcc-12` |
| Set-based, SDK kit | `debug-cross:<sdk>-<platform>-<arch>` |
| Multi-language (cmake + rust) | `debug:ninja-clang-22.1.0+rust-nightly` |
| Set-based, no tool | `debug` |
| Pinned | `project/config_key` (configuration_set is nil) |

Key collisions are resolved by appending `-2`, `-3`, etc. via
`cache.next_available_key()`.

**Unused-tool diagnostic**: a non-blocking warning surfaces when a
tool in `profile._tool_keys` provides no language any configuration
in the profile uses. The profile remains buildable; the diagnostic
prompts the user to remove dead weight.

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
module-supplied device connector tool. The serial is stable across USB
reconnections and emulator restarts.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `serial` | string | Unique device identifier (identity key) |
| `display_name` | string | Human-readable label (model name or serial) |
| `provider` | string | Module ID that owns this device type |
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
          "cross-debug": {
            "toolchain": "${VENDOR_SDK_ROOT}/cmake/cross.toolchain.cmake"
          }
        },
        "compile_commands_from": "ninja-debug",
        "clangd": "${VENDOR_SDK_ROOT}/llvm/bin/clangd"
      }
    },
    "Frontend": { "typescript": {} }
  },
  "configuration_sets": {
    "Debug":   { "App": "Debug",   "Frontend": "development" },
    "Release": { "App": "Release", "Frontend": "production"  }
  },
  "profiles": {
    "cross": {
      "configuration_set": "Debug",
      "kit_id": "ninja-cross-clang"
    }
  }
}
```

**Top-level fields**:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Workspace display name (defaults to root dir name). Published from the working copy's `name` (§2.2); the working copy wins at load |
| `projects` | Yes | Dict of project_key → project definition |
| `configuration_sets` | No | Dict of set_name → { project_key → variant } |
| `profiles` | No | Dict of profile_key → explicit profile definition |

**Project definition fields**:

| Field | Description |
|-------|-------------|
| `path` | Relative path from workspace root (defaults to project key) |
| `depends_on` | Reserved for future cross-project dependencies (ignored in v1) |
| `<type>` | Inner key determines project type; value is the type-specific config |

The type key (`cmake`, `meson`, `typescript`, etc.) is the only required field. Its
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
| `kit_id` | Tool key to use (e.g., `"ninja-clang-18.0.0"`) |

---

