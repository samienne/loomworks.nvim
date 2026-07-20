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
  meson, shell, typescript)
- [`spec/integrations/lsp/`](spec/integrations/lsp/) — per-LSP-server
  integrations (clangd, …)
- [`spec/integrations/debug/`](spec/integrations/debug/) — per-DAP-adapter
  contracts (codelldb, cppdbg, pwa-node, …)
- [`spec/sdks/`](spec/sdks/) — per-SDK-provider details (cpp_compiler, …)
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
| How the system behaves when run outside the editor (headless / standalone) | `specification.md` §16 |

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

## 2. Three-File Model

### 2.1 loomworks.json — Published Snapshot (optional)

A pure publication artifact, regenerated on `:w` from the working copy.
Contains the items the user has chosen to share with collaborators.

- **Optional** — the workspace functions normally without this file. It is
  created on the first `:w` that has anything to publish; vanishing on disk
  (e.g., a branch switch onto a branch that doesn't carry one) is a normal
  state, not an error.
- Committed or gitignored (user's choice).
- Changes from outside (branch switch, manual edit) are detected via file
  watcher and folded back into the working copy without overwriting the
  user's local changes (see §2.4).
- Paths are relative to workspace root.
- Absolute paths are **forbidden** (breaks portability).
- `${ENV_VAR}` expansion for toolchain paths.

The runtime never reads loomworks.json directly to drive behavior —
external file changes are merged into the working copy, and the working
copy is what the rest of the system consults. loomworks.json's only
roles are publication out (`:w`) and propagation in (file watcher → merge).

### 2.2 .nvim/loomworks.user.json — Working Copy & Runtime Source of Truth

The live working state and the workspace's runtime source of truth. Every
materialized item, every intent override, and every piece of session
metadata lives here. All UI mutations land here.

```json
{
  "_meta": { "version": 2 },
  "name": "reactive",
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "profiles": { ... },
  "intent": { ... },
  "default_target": { ... },
  "device": { ... },
  "lsp": { ... }
}
```

The `device` field maps profile keys to device serial strings:
```json
"device": {
    "Debug:<sdk>-<platform>-<arch>": "FMR0225108000951"
}
```

The optional `name` field overrides the workspace display name (§1.1). It is
present only when the user has set one explicitly (`lw init --name`,
`lw workspace rename`, or the editor); when absent the name defaults to the
root directory basename. Written to `loomworks.json` on publish.

The `intent` field stores explicit per-item intent overrides (see §2.4).

The `lsp` field stores per-server option overrides. Keys are server
names (e.g. `clangd`); values are option tables whose accepted shape
is defined by the integration's spec under `spec/integrations/lsp/`.
All fields within a server table are optional — omitted fields fall
back to the integration's hardcoded defaults. Saved on every
mutation (toggle from the status page) so changes survive nvim
restarts. Workspace-wide, not per-project: a single clangd binary
serves every buffer in the workspace regardless of which project
owns it. See `spec/integrations/lsp/clangd.md` §12 for clangd's
specific schema and how options map to cmd flags.

- Always gitignored.
- Written on every UI mutation (add/edit/remove project, config, profile, etc.).
- **Self-contained**: every reference inside the file resolves to data
  inside the file. The only outward references allowed are to
  module-provided defaults (e.g., `variant:debug` for module-generated
  configurations). A profile's configuration set, the configurations the
  set names, and the projects that own those configurations are all
  present in the working copy whenever the profile is present.
- Self-containment is maintained by the **implicit cascade rule** (§2.4):
  the moment a shared-only item is used (referenced by a profile, edited,
  etc.), it is materialized into the working copy.

### 2.4 Publish/Working-Copy Model

The two config files follow a **working-copy / published-snapshot** model:

- **user.json** is the live working state and the runtime source of truth.
  All UI edits go here. The runtime resolves every reference within the
  working copy.
- **loomworks.json** is a published snapshot. Generated only on explicit
  `:w`. Optional — a workspace without one is a valid, normal state.

#### Intent

Each publishable item carries an **intent** describing where the user wants
the item to live on disk. Three values:

| Intent         | In user.json | In loomworks.json | Meaning |
|----------------|--------------|--------------------|---------|
| `local`        | yes          | no                 | personal item |
| `local+shared` | yes          | yes                | published item — the default once the user touches an item |
| `shared`       | no           | yes                | reference-only — known from loomworks.json but not yet materialized |

Items in `shared` intent are visible in the UI (rendered dimmed) but their
data lives only in loomworks.json. Items in `local` or `local+shared` are
materialized into the working copy.

Per-item granularity: a project carries an intent on its declaration and
individually on each configuration, launch config, and variable
declaration. A project can be partly published (some configs `local+shared`,
others `local`). Configuration sets carry one intent (atomic). Profiles
carry one intent and default to `local` (profiles are personal by default).

**Configuration sets are the portable shared unit.** A profile is a
configuration set plus a *machine-specific* tool; a published profile may
therefore resolve as an incomplete profile on a machine that lacks that tool
(§3, incomplete-profile handling). Teams share configuration sets (and
projects), and each machine — including each CI runner — turns a set into a
buildable profile by selecting a locally-available tool. A profile MAY still
be published when a team deliberately standardizes on a toolchain.

#### Intent stickiness

Intent represents the user's **wish**, not a function of current file
presence. Once an item has an intent — assigned at creation, by implicit
cascade, or by explicit user toggle — that intent persists across external
file changes. Intent changes only when the user explicitly toggles it (`P`),
or when the item is deleted from the workspace.

This guarantees that `:w` after a branch switch behaves predictably: items
the user marked `local+shared` are republished on `:w`, even if the new
loomworks.json on disk doesn't currently contain them.

#### Initial intent (host-determined)

The intent an item receives **at creation** reflects the creating host's
purpose, and is sticky thereafter (per the rule above). The interactive
editor creates items `local` — the user adds things privately and later
chooses what to publish. A non-interactive authoring host (the command-line
runner) creates items `local+shared` — its purpose is to author the shared
contract, so a created item that never reached loomworks.json would be a
silent surprise. Either default is an explicit creation-time assignment, not
a file-presence computation, and a host MUST let the user override it at
creation (e.g. a `local` / `shared` selector). Changing an existing item's
intent afterward is an explicit user action in any host.

**Profiles are excepted**: every host creates a profile `local`, regardless
of its default for other item kinds. A profile binds a configuration set to
resolved toolchains, and a toolchain is a property of the machine that
detected it — publishing one asserts a build environment the reader may not
have. The portable unit is the configuration set, which each machine pairs
with its own locally resolved toolchain. A host MUST still honour an explicit
share request at creation, and publishing a profile afterward remains a
normal explicit action (it pulls its set and projects along by the closure
rule below).

#### Effective intent (transitive)

An item's **effective intent** is the union of its explicit intent and the
implicit intent forced by every item that references it:

- A `local+shared` configuration set forces the configurations it maps to,
  and the projects that own them, into effective `local+shared` —
  regardless of those leaves' explicit intent.
- A `local` profile forces its configuration set, the configurations the
  set names, and the projects that own them, into effective `local`.

Effective intent affects only **serialization** (what gets written where on
`:w`) and **resolvability** (whether the working copy can resolve a
reference without loomworks.json). Explicit intent is unchanged by
transitive promotion. When a parent item's intent later relaxes (e.g., the
parent is unshared), the implicit promotion vanishes too — leaves return to
their explicit intent.

#### Implicit cascade on use

When the user **uses** a `shared` item — activates a profile that
references it, edits it, or names it from the UI — the item is
materialized: its data is copied into the working copy and its explicit
intent becomes `local+shared`. This rule applies recursively:
materializing a profile materializes the configuration set it names;
materializing a configuration set materializes the project configurations
it maps to.

Materialization is shallow per project: only the configurations named by
the materialized parent are materialized. Other configurations on the same
project remain `shared`.

#### Modified indicator (`+`)

An item shows `+` when the next `:w` would change loomworks.json for that
item. The published baseline is the last-loaded or last-written
loomworks.json content.

| Effective intent includes `shared` | In baseline | Content matches | `+` | `:w` action |
|---|---|---|---|---|
| yes | no  | —   | `+` | add to loomworks.json |
| yes | yes | yes | —   | no-op |
| yes | yes | no  | `+` | update loomworks.json |
| no  | yes | —   | `+` | remove from loomworks.json |
| no  | no  | —   | —   | no-op |

The `+` indicator **bubbles up**: if any child of a project is modified,
the project header also shows `+`.

#### Removed-upstream indicator

When an external loomworks.json change removes an item that the user has
as effective `local+shared`, the item is rendered with a distinct visual
indicator (separate from the `+` modified marker). This signals: "your
published copy persists, but upstream removed this item." The user
resolves explicitly:

- **Republish** — `:w` re-adds the item upstream.
- **Demote to local** — `P` cycles intent to `local`, dropping the
  publication wish.
- **Delete** — remove the item from the workspace.

The exact glyph is a UI-spec choice (see `spec/ui.md` and `spec/ui-v2.md`).
The indicator is a **session** affordance: it requires knowing the
previous baseline to detect "was there, isn't now," so it shows only after
an external change within the running session. After Neovim restarts, the
same condition renders as a regular `+`. Behavior is identical either
way; only the visual cue changes.

#### Per-configuration merge

Projects from loomworks.json and user.json are merged at the
**configuration level**, not the project level. If shared defines Debug
and Release, and user defines Debug (modified) and Debug-asan (new), the
merged project has all three: shared Release, user Debug, user Debug-asan.
User wins per-key within:
- `type_config.configurations` — per config name
- `launch` — per launch config name
- `variables` — per variable name

Project-level fields (`path`, `type`, `depends_on`, module settings like
`compile_commands_from`) come from user.json if present, otherwise from
shared.

#### Saving (`:w`)

`:w` on the status buffer regenerates loomworks.json from the working copy:

- For every item with effective intent including `shared`, write current
  content to loomworks.json.
- Items previously in the published baseline whose effective intent no
  longer includes `shared` are removed from loomworks.json.
- After write, the published baseline is updated to match the new
  loomworks.json. `+` and removed-upstream indicators clear.

If the working copy has no items with effective intent including `shared`,
`:w` is a no-op — empty published snapshots are not written, and any
existing loomworks.json with no remaining shared items becomes empty (or
absent). The exact semantics of "remove file vs leave as `{ "projects": {} }`"
is an implementation choice; either is spec-compliant.

#### Reverting (`:e` / `:e!`)

`:e` and `:e!` operate on the whole workspace, mirroring vim's
buffer-reload semantics:

- **`:e`** is refused when any item has unsaved divergence — i.e., any
  effective-`shared` item shows `+` or the removed-upstream indicator.
  The refusal message points the user at the two safe paths: surgical
  per-item resolution (see below), or `:e!` to discard everything. When
  no divergences exist, `:e` is a no-op (the working copy already
  matches the published baseline for shared items).
- **`:e!`** force-reverts the working copy to match the published
  baseline:
  - Items with effective intent including `shared` that exist in
    baseline: content reverts to baseline.
  - Items with effective intent including `shared` that are not in
    baseline (locally added, or flagged removed-upstream): intent
    demotes to `local` — the publication wish is dropped, content is
    preserved as a personal item.
  - Items with effective intent `local`: untouched.
  - All `+` and removed-upstream indicators clear.

  `:e!` does not delete data: modifications revert to baseline,
  publication wishes for unmatched items drop. Used sparingly — this is
  the "give up all my unpublished work" verb.

#### Per-item conflict resolution

Per-item actions (invoked via context menu / action picker on the cursor
item) provide surgical resolution when divergence exists. These are how
the user resolves a `+` or removed-upstream condition without going
nuclear with `:e!`:

- **Publish this item** — writes the cursor item's current content to
  loomworks.json, leaving the rest of loomworks.json as-is. Updates the
  published baseline **for this item only** — its `+` clears, other
  items' indicators are unaffected. Effective-intent cascade applies the
  same way `:w` does (publishing a config set publishes the
  configurations it forces shared).
- **Revert this item** — replaces the cursor item's content with the
  baseline content; intent unchanged. For a removed-upstream item,
  demotes intent to `local` (the user confirms they no longer want the
  item shared) and clears the indicator.

Together, `:w` / `:e!` are the bulk verbs and the per-item actions are
the surgical ones. A user with five `+`-marked items and one
removed-upstream item can selectively publish three, revert one, demote
one, and end up clean — without ever touching `:e!`.

Per-item publish writes a partial loomworks.json — only the named item is
regenerated. The rest of the file is preserved as-is, including items
that the user has modified-but-not-ready and items the user has not
touched. This is the key behavioral difference from `:w`, which
regenerates the whole file from the working copy.

#### External changes

When loomworks.json changes on disk (branch switch, git pull, manual edit):

- The published baseline updates from the new file content.
- For every materialized item (intent `local` or `local+shared`):
  - If content matched the old baseline, content updates to the new
    baseline (auto-pull). Intent unchanged.
  - If content diverges from the old baseline, content stays.
    Intent unchanged. `+` recomputes against the new baseline.
- For `shared` items: the visible data tracks loomworks.json directly.
- Items removed upstream that the user had as effective `local+shared`:
  flagged with the removed-upstream indicator (see above). Intent
  unchanged.
- New items appearing upstream: appear as `shared` (reference-only).

Intent is **never** changed by an external file change — only by explicit
user action (`P`, `:e` on a removed-upstream item, or item deletion).

#### loomworks.json missing

When loomworks.json does not exist on disk:

- The published baseline is empty.
- The workspace functions normally from the working copy.
- Every item with effective intent including `shared` shows `+` (would be
  written on next `:w`).
- The status page header surfaces "loomworks.json not on disk — `:w` to
  publish."
- `:w` creates the file (if there's anything to publish).
- `:e` is a no-op (nothing to revert against).

Reappearance of loomworks.json (e.g., switching back to a branch that
carries one) is handled by the External changes rules above.

#### Publish toggle (`P`)

The `P` key on the status page cycles the explicit intent on the item
under the cursor through the three values
(`local` → `local+shared` → `shared` → `local`). Toggling saves to
user.json and refreshes the display.

Cycling intent never deletes the item's data: the working copy retains
the representation across cycles. `:w` consolidates the on-disk state to
match the declared intent.

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
  may have build directories outside `.nvim/build/`.
  The cache key for these is their absolute path (no `.nvim/` prefix to
  strip). `absolute_build_dir()` detects absolute paths and returns them
  unchanged. Deletion safety requires the path to be under workspace root.
- Atomic writes (temp + fsync + rename) with .bak recovery.

### 2.5 Three-file reconciliation

The merge operation produces the active set by reconciling all three files:

| In config | In cache | Result |
|-----------|----------|--------|
| Yes       | Yes      | Normal — show cached state |
| Yes       | No       | Available — unconfigured |
| No        | Yes      | Orphaned — shown distinctly, user cleans manually |

### 2.6 Environment variable resolution for toolchain paths

`loomworks.json` uses `${ENV_VAR}` references for toolchain paths (e.g.,
`"toolchain": "${VENDOR_SDK_ROOT}/cmake/cross.toolchain.cmake"`). These
references are never stored resolved in `loomworks.json` — that file stays
portable. The cache stores the resolved absolute path alongside other tool
properties.

**Where each form lives**:

| File | Stores | Example |
|------|--------|---------|
| `loomworks.json` | Variable reference | `${VENDOR_SDK_ROOT}/cmake/cross.toolchain.cmake` |
| `cache.json` | Resolved absolute path | `/opt/vendor-sdk/10/cmake/cross.toolchain.cmake` |

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

### 4.9 Project Rename Propagation

When a project key is renamed (old_key → new_key), all references are
updated atomically:

1. **Project**: update `key` and (when `path` defaulted to the key)
   `path` on the Project domain object.
2. **Profile mappings**: each profile's resolved mappings dict is
   keyed by project_key string; entries are rekeyed.
3. **ConfigUnit ids**: each ConfigUnit registered under the project
   has its `id` rekeyed from `old_key/config_key` to
   `new_key/config_key`. `_init_project_key` follows.
4. **ConfigurationSet mappings**: stored as `project_object → config_object`,
   so the Project identity is preserved and no map rebuild is required.
5. **user.json**: re-saved with the new key. **cache.json**: re-saved
   so the rekeyed ConfigUnit ids land on disk.

Build directories on disk are not renamed. Cache entries' `build_dir`
fields preserve their absolute paths after rename — the existing build
directory continues to be used. A subsequent delete + reconfigure
yields a fresh directory under the new key per the module's path
formula.

Rename is rejected when:
- The new key matches another existing project key (case-insensitive,
  matching the case-collision rules under §4.6).
- The new key fails `validate_path_name` (slashes, dots, sanitization
  collision).

On save failure, the rename rolls back: project.key, project.path,
profile mappings, and ConfigUnit ids are restored.

### 4.10 Configuration Set Rename Propagation

When a configuration set is renamed (old_name → new_name):

1. **Set**: update `cs.name`.
2. **Profiles**: each profile with `_configuration_set_name == old_name`
   is updated to `new_name`. The profile key (derived from
   `set_name:tool_keys`) is re-derived.
3. **user.json**: re-saved. **cache.json**: re-saved with the new
   profile keys.

Rename is rejected when the new name matches another existing set
(case-insensitive) or fails `validate_path_name`. Rolls back on save
failure.

**Profile rename**: profile keys are derived from configuration set
name + tool keys, not user-named. Profiles cannot be renamed
directly; renaming the underlying set or changing the tool selection
yields the equivalent re-derivation.

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

**Recovery from stuck state**: A task whose lifecycle never reaches the
release path (e.g., a crash before subscription wiring completes) can
leave a lock held with no live holder. The Tasks section of the status
page (`spec/ui.md` §1.9) surfaces the lock and per-task state, and
exposes a **force-release** action that drops the lock counts to zero
and replays the FIFO queue. The force-release is idempotent with
respect to the real holder's eventual release call — if the holder
ever does fire, it sees zeroed counts and no-ops.

**Cancel cascade**: A user-initiated cancel on a single task stops
that task's overseer process. Chained next-tasks (the build link of a
configure→build chain, or the next task in a multi-stage operation)
auto-abort because each `do_start` checks `token:is_cancelled()`
before launching and any subsequent `:next()` link rejects when the
cancelled Future propagates. Profile-level and project-level cancel
walk the matching units and cancel each running task individually —
the cascade then takes care of every dependent waiter.

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

### 5.8 Process priority

Long-running tasks launched on behalf of the user — configure, build,
clean, and test runs — must yield CPU and I/O to the editor so the UI
and language server stay responsive while the build runs.

On platforms where the OS exposes a CLI mechanism to drop both CPU and
I/O priority for a spawned child (Linux: `nice` + `ionice`), the
implementation prepends that mechanism to the task's cmd. The
prepended wrapper must be:

- **Transparent to the cmd contract** — original args appear unchanged
  after the prefix; the cmd remains an exec-style argv array.
- **Best-effort** — if the wrapper binaries are missing, the task
  still launches with the original cmd. No errors raised.
- **Scoped to user-launched long tasks** — configure, build, clean,
  test. Short, user-blocking probes (target enumeration, option
  introspection, version checks) are excluded so the editor doesn't
  feel sluggish.
- **Excluded for debugger sessions** — debug-attached test runs go
  through the DAP path and must not be wrapped (would distort
  debugger timing and confuse the adapter).

Platforms without a clean CLI mechanism (Windows, macOS) skip the
wrap and rely on the OS scheduler's defaults. Whether to wrap is a
boolean decision per-task — there is no per-platform priority knob in
the spec.

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
| `on_unexpected_exit(info) → decision` | Restart policy for an unexpected client death (see §9.6). `info` carries `{ server, root_dir, exit_code, signal, attempt, args }`. `decision` is `{ restart: boolean, args?: string[], reason?: string }` |
| `reset(root_dir)` | Clear any adaptive state for a root (UI Reset action) |
| `reset_label` | Display label for the UI Reset row |

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

### 9.6 Restart on unexpected exit

`lsp.lua` wraps every managed client's `on_exit` so it can distinguish
three exit modes and route them correctly:

| Mode | Trigger | Action |
|------|---------|--------|
| Managed stop | Integration called `lsp.mark_managed_stop(client.id)` before `client:stop()` (e.g. its own `on_active_set_changed` restart) | Skip dispatch — the integration is restarting itself. |
| Clean external stop | `exit_code == 0` and `signal in {0, 15}` and not managed | Set per-`(server, root_dir)` suppression flag — `:LspStop` is the user's hard kill, no auto-restart until a fresh `LspAttach` or UI Reset clears it. |
| Unexpected death | anything else | Dispatch to the integration's `on_unexpected_exit(info)`. If it returns `restart = true`, re-enable the server through nvim's normal path (the integration's `cmd_factory` will run again with whatever adaptive state it keeps). |

A generic throttle caps restart velocity at **4 attempts per 5-minute
sliding window** per `(server, root_dir)`. When the cap is reached,
subsequent attempts defer until the oldest timestamp falls out of the
window. There is no permanent give-up at the lsp.lua layer — `:LspStop`
remains the user's escape hatch.

`lsp.lua` exposes:

- `mark_managed_stop(client_id)` — integrations call this before stopping their own clients
- `wrap_on_exit(server, user_on_exit) → fn` — integrations install this as `config.on_exit` from `build_config()` so the user's `on_exit` still runs and our dispatcher gets a turn after
- `is_suppressed(server, root_dir) / clear_suppression(server, root_dir) / reset_attempts(server, root_dir)` — public so the UI Reset action can recover from suppression and throttle without touching server-specific code

Adaptive state (e.g. clangd's `-j` step-down) lives entirely inside
the integration. Core sees only the opaque `LspRestartDecision`.

---

## 10. SDK Provider Contract

An SDK is a resolved platform installation (e.g., an Android NDK, an
embedded vendor toolchain, a cross-compiler distribution) that supplies
tools to one or more modules. SDK providers
are pluggable: each provider lives at `lua/loomworks/sdks/<id>.lua`
and registers itself by being required from `lua/loomworks/sdks/init.lua`
or another runtime path file.

### 10.1 Provider interface

Each provider table exposes:

| Field | Purpose |
|-------|---------|
| `id` | Provider identity (e.g., `"android-ndk"`) — stable across versions |
| `display_name` | Human-readable name shown in pickers and status |
| `detect_all() → { path, version }[]` | Enumerate installations on the host. Pure detection — no validation, no domain object creation |
| `validate(path) → boolean` | Return whether a given path looks like a valid installation of this SDK type |
| `create_sdk(key, path, version) → SDK` | Construct a `loomworks.SDK` domain object from a validated installation |
| `query_capabilities(sdk, module_id) → table\|nil` | Return opaque capability data this SDK can offer to a given module, or `nil` if it has nothing for that module. `module_id == nil` returns the supported module ids array |

**Declaring an installation.** An SDK is normally declared by supplying a path,
which the provider validates — identifying the installation and deriving the
facts (such as version) that the key is built from. A provider MAY derive a key
that encodes more than the version (for instance a path-derived token, so two
installations of the same version at different paths stay distinct); a
provider-derived key is the installation's identity and MUST be preserved
verbatim across save/load.

A user MAY **force** a declaration whose path fails identification — an
installation that cannot report on itself — by supplying the identifying facts
explicitly. The path MUST still exist, so a mistyped path is still refused. A
forced declaration carries only the facts the user gave: where a version was not
supplied it is unknown, and the installation therefore forfeits version-based
selection (§16.3) and is referenced by its full key.

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
provider can no longer find the installation (e.g., the SDK was moved
or uninstalled), the profile renders as incomplete with a rebase
action. No fallback guessing — incomplete profiles surface
explicitly.

When a profile has an SDK and a module asks for a tool, the resolver
consults the SDK first via `SDK:query(module_id)`. If the SDK
returns nil, the module falls through to host-tool detection. If
neither yields a tool and the profile has no explicit override, the
profile is incomplete.

**Incomplete profiles refuse build operations.** Configure, build,
launch, and debug all gate on a buildability check at every entry
point: an incomplete profile can be created, edited, persisted to
loomworks.json, and shared with collaborators, but cannot be
executed against. The error is module-agnostic and points the user
at the status page to assign a tool/SDK. Without this gate the
build chain runs with nil tool data, the build directory resolves
from a config name that may have fallen back to a phantom
Configuration, and on-disk artefacts come out malformed.

### 10.5 SDK provider implementations

Each SDK provider documents its detection logic, validation rules,
and per-module capability shape in its own spec file:

- [`spec/sdks/cpp_compiler.md`](spec/sdks/cpp_compiler.md) —
  User-declared C/C++ compiler (cross-compiler / custom build).

Third-party providers follow the same shape: implement the contract
above and document the per-module capability shape alongside.

Optional provider hooks beyond the base contract:

- `path_prompt: string` — overrides the generic `<display_name>
  SDK path` text in the Add-SDK dialog. Useful when the
  installation is not a directory (e.g. a compiler binary).
- `derive_key(info, path) → string` — overrides the default
  `<type>-<version>` key shape. Useful when one user can have
  multiple distinct installations of the same type and version
  (e.g. two custom compiler builds at different paths).
- `display_name_for(sdk) → string` — overrides
  `SDK:display_name()` per instance so labels can depend on
  query-time information (e.g. detected compiler family).

### 10.6 Future direction

Profile-level toolchain selection is now language-keyed: profiles
carry a flat array of tool keys (`profile.tools`), each tool declares
its language coverage (`Tool.languages`), and each Configuration
declares the languages it needs (`Configuration.languages`, defaulting
to `module.languages`). SDK-supplied tools land in their module's
`_tools` registry via `Workspace:_enrich_tools_from_sdks` on every
remerge, identified by the same key shape host tools use so
cross-module identity is preserved. SDK refresh remains cheap because
the registry is rebuilt from cache + detection on each load —
profiles store only keys, not tool_data, except in the legacy
shape which migrates transparently on first save.

Post-configure language detection (cmake file-api, meson introspect)
is a future refinement — a soft diagnostic that suggests adding a
language to a configuration when the actual configure enabled more
than was declared. Not authoritative; user remains the source of
truth for `Configuration.languages`.

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

**`device_install(tool_data, device_serial, artifact_path) → { cmd, args, env?, check_output? }`**

Return an overseer-compatible command spec for installing an
artifact onto a device. Does NOT execute the command — core runs it
via overseer. Always reinstalls (no freshness tracking).

`check_output(lines: string[]) → string|nil` is an optional failure
detector. Some device connectors exit with status 0 even when an
install is rejected by the device-side package manager; without
parsing the output, the build → deploy → install → launch chain
falls through silently and the device launches the previously
installed version of the app. Returning a non-nil string fails the
install task and breaks the chain. Modules that wrap exit-code-honest
connectors may omit this field.

**`device_launch(tool_data, device_serial, launch_info) → { cmd, args, env?, check_output? }`**

Return a command spec to launch the installed app on a device.
`launch_info` is module-specific metadata produced by
`resolve_launch_info()`. `check_output` follows the same contract
as `device_install` — used to surface launch failures that the
connector reports in stdout while exiting 0.

**`device_stop(tool_data, device_serial, bundle_name) → { cmd, args, env?, check_output? }`**

Return a command spec that force-stops the app on the device.
Session tracker calls this from `stop()` when the active run is a
device launch so stop paths actually terminate the on-device process
rather than merely closing the local log stream. `check_output`
follows the same contract as `device_install`.

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
relevant connector tool. No v1 core module ships a device interface;
device-capable modules (e.g. mobile/embedded targets) live in
separate plugins and document their connector usage in their own
specs.

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

11. **Validity is the operation gate**: Every state-bearing domain object
    (Profile, Configuration, ConfigurationSet, LaunchTarget, ...) exposes
    `:is_valid() → bool, string[]` returning a yes/no plus a list of
    human-readable reasons (empty when valid). Build, configure, launch,
    and debug operations refuse to run on an invalid target — the per-method
    guards return early with an error citing the reasons. The same
    predicate drives the status-page Diagnostics section (each invalid
    object's `:diagnostic()` is a thin formatter on top of `:is_valid()`)
    and the inline UI markers (e.g. `⚠ missing source`). One predicate,
    three views — gate, diagnostic, indicator — guaranteed in sync.

12. **Stubs preserve identity, not data**: Source-missing references
    (configurations referenced from a config_set or inherits chain that
    don't resolve to a live source) are kept as `_source_missing = true`
    Configuration stubs in the project's registry. This preserves data-
    graph soundness across temporary breakage (branch switches, in-flight
    edits) — every reference always resolves to *some* object, so consumers
    don't need nil handling. Stubs are filtered from every serialization
    path (`_serialize_user`, `_serialize_project_partial`,
    `_serialize_project_shared`, `_user_config_from_objects`,
    `_type_config_for_module`) — they never reach `loomworks.json`,
    `user.json`, or the in-memory user_overlay that drives subsequent
    remerges. The reference TO a stub (in `ConfigurationSet:raw_mappings`)
    IS preserved on save so the user's intent isn't silently cleaned up.

    Stubs are also garbage-collected promptly when the last referrer
    is removed: `ConfigurationSet:update_mapping` drops a stub from
    the project's `_configurations` array if the change leaves it
    with no remaining referrer (no other set mapping, no sibling
    inherits chain). Without this, fixing a stale mapping in the UI
    would leave the stub visible in the project's config list until
    the next full remerge. Diagnostic surface deduplication: the
    project-side `Configuration:diagnostic` for `_source_missing`
    stubs is suppressed when a `ConfigurationSet` already covers
    the same condition — the set-side message is more actionable
    and the jump target lands on the broken mapping rather than the
    stub. Sibling-inherits-only stubs (no set referrer) keep their
    project-side diagnostic.

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

---

## 16. Headless / Standalone Execution

The system runs in two execution environments: the **interactive editor
host** and a **non-interactive (headless) host**. All contracts in §1–§15
hold in both, except those explicitly scoped to the editor — UI (§6),
Neovim commands (§14), LSP integration (§9), auto-load (§13), and live
file-tracking reconciliation (§2.5). A headless host performs a bounded
subset of behavior: resolve a profile and run its build / clean / test
tasks to completion, reporting a process exit status.

### 16.1 Runtime-host neutrality

The behavioral contract is independent of the host that provides the Lua
and asynchronous runtime. Any host supplying the required primitives — a
structured filesystem, process spawning, an asynchronous I/O event loop,
and JSON encoding/decoding that distinguishes object, array, and null
(including the empty-object vs empty-array distinction, §1.9) — MUST
produce identical results. State serialized by one host MUST be readable,
with identical meaning, by any other host.

### 16.2 Source of truth without the working copy

A headless invocation MUST be able to resolve any **published** profile to
its build commands from the published snapshot (§2.1) plus the cache (§2.3)
alone, with no working copy (§2.2) present. Publishing (§2.4) therefore
MUST emit a snapshot self-sufficient for this resolution. When a working
copy is present it MAY be read as input. A **build** (§16.4) MUST NOT create
or modify it — build invocations are non-mutating so CI runs stay
reproducible; an explicit **management** operation MAY write it (§16.9).

### 16.3 Explicit profile selection

The active profile is working-copy state (§4.2) and is not assumed in a
headless invocation. The profile to operate on MUST be selected explicitly
by the caller. Absent an explicit selection, the invocation is an error
unless exactly one published profile exists — the system never guesses a
default.

A profile MAY be named by a **truncated tool selector** — a prefix of a tool
key that omits trailing detail, such as a compiler family plus major version
(`ninja-clang-18`) or a toolchain family plus major version without its
edition (`msvc-17`). A CI matrix can therefore name a toolchain without
pinning either the exact patch version or the specific edition installed on a
given runner image.

Matching is **anchored at segment boundaries**: the selector must be followed
in the candidate key by a version separator or a segment separator, so a
truncated selector never resolves a different segment (a `…-1` selector
matches neither `…-18` nor `msvc-17`). It is a prefix, not a substring —
`msvc-17` does not match `ninja-msvc-17-…`. Among candidates the highest
matching version wins; when candidates carry no distinguishing version (two
editions of the same toolchain) the choice MUST still be deterministic and
independent of enumeration order. When a selector matches more than one
**profile** the invocation is an ambiguity error, never an arbitrary pick.

### 16.4 Cache-cold vs cache-warm

Build-unit readiness derives from the cache (§3.1). For a build unit with
no valid cache entry, a headless invocation MUST perform the full readiness
sequence — tool detection (§3.3) then configure (§5.2) — before build. For
a unit with a valid cache entry it MAY build directly. Tool identity
resolves from live detection when available, otherwise from cached tool
data (§1.5, §2.3); resolution MUST succeed from cache alone when detection
has not run.

### 16.5 Toolchain provisioning boundary

A headless host detects toolchains present on the system; it does not
install them. Provisioning build tools is outside the system's contract,
except SDK-provided toolchains (§10).

### 16.6 Non-invasiveness

A headless build is read-only toward project sources and toward the working
copy. Only the cache and build directories are written, under the safety
rules of §2.3 and §5.3. This contract does not itself serialize cross-process
concurrent access to a shared build directory; a host MAY add advisory
exclusion. loomworks does: configure/build/clean hold a **per-build-directory
advisory lockfile** — an `O_EXCL` create (atomic across processes) with an
mtime heartbeat so a crashed holder's lock goes stale and is reclaimed. The
editor and the CLI share this lock, so neither builds a directory the other is
building; acquisition is **fail-fast** (the loser reports the holder and
declines rather than waiting). A stale lock is reclaimed automatically after
the heartbeat window; `lw unlock` clears one immediately.

### 16.7 Reporting

Success or failure is reported via process exit status; task output streams
to standard output and standard error. No editor UI is required or
produced.

### 16.8 Host-determined module availability

The set of modules available to a host is determined by that host. A build
unit whose module is unavailable in the current host is reported and
skipped; consistent with §8.0, its declaration is preserved and does not
invalidate the workspace or other units.

### 16.9 Builds are read-only; management may author

A **build** (§16.4) is read-only toward configuration: it never creates or
modifies projects, configurations, configuration sets, or profiles. This is
what keeps CI runs non-mutating and lets the headless host coexist with the
editor.

An **explicit management** operation MAY author — bootstrap a workspace,
select the active profile, or (where supported) create/edit items — but only
when the caller invokes it directly; it is never part of a build. Management
writes follow the same working-copy model as the editor (§2.4): they land in
the working copy (§2.2), and the published snapshot (§2.1) changes only on an
explicit publish. A read-only / CI invocation runs no management operation.

### 16.10 Toolchains outside the search paths

*(Reserved. Section numbers §16.11+ are referenced throughout, so this number
is retained rather than reused.)*

A build machine whose toolchain is not on the host's search paths makes that
installation usable by **declaring it** (§10.1) — the declaration is validated,
identified, and produces a toolchain like any detected one, so the profile pins
it and selection (§16.3) applies unchanged.

A per-invocation override that satisfied a profile's pin from a bare executable
path was considered and **deliberately rejected**: probing an executable yields
its own identity, but not the surrounding facts a module needs to build with it
(a build-system generator, for instance). Reconstructing those would mean either
inferring them from the pinned key — keys are opaque identifiers and are never
parsed (§1.5.2) — or silently assuming a default that is wrong for some
toolchains. Declaration avoids this because the provider *constructs* the
toolchain rather than guessing at it.

### 16.11 Runner distribution and system-Lua resolution

The standalone runner separates a **generic runtime host** (the Lua VM and
asynchronous primitives of §16.1) from the **system Lua** (the behavioral
implementation of §1–§15). The host carries no behavioral logic of its own;
per invocation it resolves system Lua from exactly one source, chosen by
precedence:

1. an explicit caller override naming a directory;
2. a **development source** — a working tree designated in host
   configuration — when the caller opts into it;
3. otherwise the **release source** — a verified release bundle.

Absent (1) and (2), the release source is used. The chosen source is fixed
for the whole invocation. The resolution is a host concern: it does not
affect any §1–§15 contract, and system Lua behaves identically whichever
source supplied it.

### 16.12 Release integrity

A release bundle MUST be cryptographically verified against a trusted public
key carried by the host before any of its Lua executes. Verification covers
a signed manifest that binds the identity and content hash of every bundle
artifact; an artifact whose hash does not match, or a manifest whose
signature does not verify, MUST NOT execute. Verification integrity MUST NOT
depend on transport security: a bundle obtained over an untrusted or
intercepted channel is accepted if and only if its signature verifies. A
development source (§16.11) is exempt from verification — it is local,
explicit, and caller-owned. The component that performs verification is part
of the host, never part of the bundle it verifies.

### 16.13 Acquisition and activation

Acquiring a release bundle — an initial install or an update — MUST verify
it (§16.12) before it becomes active. Activation MUST be atomic and MUST NOT
overwrite the code of a running invocation; a failed or partial acquisition
MUST leave the previously active bundle intact, so a runner is never left
without a working system Lua. Acquisition and activation are management
operations (§16.9): they are never performed as part of a build (§16.4), so
a read-only or CI invocation neither fetches nor mutates the active bundle.

### 16.14 Host/bundle compatibility

A release bundle declares the minimum runtime-host capability it requires. A
host that does not meet a bundle's minimum MUST refuse to execute it — rather
than fail unpredictably — and MUST report that a host update is required.
Within its compatible range a single host build executes any bundle, so
behavioral updates ship as bundles without replacing the host.

### 16.15 Host acquisition integrity

The host cannot verify itself — the component that checks a signature (§16.12)
is inside the host. A host binary's integrity is therefore established
out-of-band: it is obtained and checked against a hash published through a
trusted channel *before* its first execution, and only a matching binary is
run. Installation is that binary placing itself where it can be invoked; it is
not part of the verified-bundle chain and MUST NOT be assumed to have verified
the running binary. Once trusted this way, the host bootstraps the bundle chain
(§16.12–16.13).

### 16.16 Headless test runs

A headless **test** invocation resolves a profile and ensures it is configured
and built (§16.4) — **skipping the build of any unit whose native batch runner
rebuilds its own targets (§8.9.2), since that build would be redundant** — then
runs each buildable unit's tests through the native batch runner
(`run_command_all`, §8.9.2) — not the editor's structured per-test path.
Configuration is still ensured for every unit: a self-rebuilding runner assumes
an already-configured build directory, not an unconfigured one. Each runner's process exit
status is authoritative; the invocation's exit status is success iff the build
succeeded and every runner reported success. A unit whose module exposes no
batch runner contributes no tests; a profile with no test runners at all is
reported as such, not a failure. Like a build (§16.4), a test run is read-only
toward configuration (§16.9).

A headless test invocation MAY forward caller-supplied arguments to the native
batch runner (e.g. a parallelism knob), and MAY request machine-readable
(JUnit XML) results written to a caller-specified location — a single file per
invocation, or one file per unit (a label suffix distinguishing them) when a
profile runs several. The runner maps both to its native mechanism; a runner
that cannot emit JUnit reports that without failing the run.

### 16.17 Headless launch (run)

A headless **run** invocation resolves a profile (§16.3) and a **launch
target**, then runs the editor's launch chain (§8.6, "Build flow"): build the
target and its dependencies (§16.4), execute **deploy** steps (§8), and launch.
The launched process's exit status is the invocation's exit status. It runs
**attached to the invoking terminal** — inherited standard input/output/error,
and (on Windows) not hidden — so its output streams live, it can read input,
and a GUI window appears, exactly like launching the binary directly. This is
distinct from the build/test steps, whose tool output is captured. The run is
read-only toward configuration (§16.9) and, like the editor's non-debug launch,
excludes debugger attachment and device targets (both deferred).

**Launch target selection.** The launch target is one of:

- the profile's **default target** (§8.6) when none is named;
- a **named target** — either a **build target** (its executable artifact,
  resolved via the module) or a **command launch configuration** (§8.7).

A configuration pins exactly one configuration per project, so a target
reference needs no configuration qualifier; it resolves within the profile.
Project qualification (`project:target`) disambiguates a bare name that is
present in more than one project. A bare name matching **both** a build target
and a command launch configuration is an error until qualified. Selection is
explicit throughout: with no named target and no default set, the invocation
errors unless exactly one launchable target is in scope — the system never
guesses.

**Argument forwarding.** Positional arguments after a `--` separator are
forwarded verbatim to the launched program (a command configuration's own
declared arguments precede them). The separator is required to pass arguments,
so the optional target-name positional is never ambiguous with program
arguments.

**Shared code paths.** Resolution, dependency build, deploy, and the launch
command/spec are the same seams the editor drives; the headless runner differs
only in executing the resolved spec directly rather than through the editor's
task runner (§16.1).

**Setting the default target** is a management operation (§16.9): it selects,
per profile, the default build target and writes it to the working copy
(§8.6, "Default target storage"). No target is ever named "default" — the
default is a property of the profile, not a reserved target name.

### 16.18 Headless introspection

A headless invocation MAY **query** read-only facts about a resolved profile
(§16.3) as deterministic, machine-readable output for scripting — most usefully
a project's **build directory**, so a CI job can locate build artifacts without
reconstructing the layout. A query performs no build and no management writes
(§16.9); the build directory it reports is the same deterministic path a build
would use, known once the profile pins a toolchain, so the query is valid before
any build has run. Introspection is scoped to a `(profile, project)` pair, since
a build directory is a per-project coordinate; the reported facts a caller MAY
request include the build directory, the pinned configuration, the last known
build state, and the resolved toolchain.
