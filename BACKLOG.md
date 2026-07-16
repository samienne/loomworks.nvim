# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Standalone CLI — deferred pieces

The standalone command-line runner ([specification.md §16](specification.md),
ARCHITECTURE.md "Standalone Runner & Distribution") ships a simple v1
(`build`, `test`, `profiles`). Deferred beyond v1:

- **Headless third-party module loading.** v1 bundles only the core modules;
  external module plugins (e.g. OHOS / harmony) are editor-only. A discovery /
  loading mechanism (bundling into the dist, or a configured module search
  path) is needed for headless external-module builds (spec §16.8).
- **Project-committed wrapper.** `lw init` writing `./lw` +
  `wrapper.properties` into a project, with project-pin-wins version
  resolution. v1 is system-wide (per-user, on PATH) only.
- **`lw run` launch + device targets.** Non-debug launch (build → deploy →
  execute) is a fast-follow; debug launch (DAP) and device install / launch
  stay editor-only.
- **Keyless signing / provenance.** v1 signs a `SHA256SUMS` manifest with
  minisign; Sigstore / GitHub artifact attestations are a later upgrade.
- **Cross-process build-dir locking.** v1 does not serialize concurrent
  editor + CLI access to a shared build directory (spec §16.6); an advisory
  fail-fast lock is a possible addition.

---

## UI v2 redesign (in design phase)

The current status-page UI evolved feature-by-feature and accumulated
IA debt: one tree for all topics, dialog-heavy editing, modal traps,
no visualization of cross-project relationships. Multi-project flows
(deploy steps especially) are tedious to define and easy to get
wrong.

Design phase artifacts:

- [`spec/v2-design-brief.md`](spec/v2-design-brief.md) — pain
  inventory, capability wishes, directional ideas, constraints
- [`spec/v2-design-scenarios.md`](spec/v2-design-scenarios.md) —
  concrete user-flow scenarios to design against and (later) test
  against

Both are throwaway design inputs, intended to be consumed by a
fresh-context design session. They die when v2 ships (or when the
effort is dropped). Do not maintain them as living docs.

---

## LSP auto-restart on crash (integration-declared)

Generalize the clangd-specific restart loop that sami had in their personal
config into an opt-in field on LSP integrations. Motivation: on very large
codebases clangd routinely gets OOM-killed — the user wants it re-launched
automatically, with `--j=<n>` halving on each SIGKILL so it settles into a
memory budget the system can actually support.

Proposed shape on integrations:

```lua
M.auto_restart = {
    on_signals = { 9, 11 },         -- SIGKILL, SIGSEGV
    on_sigkill_adapt_cmd = function(cmd, attempt_state)
        -- mutate cmd (halve --j=N) and return the new cmd + updated state
    end,
}
```

`lsp.lua` would wire `on_exit` generically, call the integration's
`on_sigkill_adapt_cmd` when present, and re-install via `vim.lsp.config` +
`vim.lsp.enable`. Default for clangd: halve `--j=` on SIGKILL, reset to 12
on SIGSEGV.

Also consider an upper-bound restart count and a backoff so a truly-broken
config doesn't hot-loop forever.

User-facing: users can set `auto_restart = false` on a server to opt out;
leaving it unset gets the integration's default behavior.

---

## MSVC toolchain support for the meson module

Meson builds fine with MSVC (`cl.exe`) on the ninja backend, but only
when invoked under an environment where `vcvarsall.bat` has run — that
sets `INCLUDE`, `LIB`, `PATH`, etc. for the target architecture. The
meson module's compiler detector (`lua/loomworks/cpp_compilers.lua`)
currently only finds gcc/clang on PATH; `cmake_kits.lua` already has
the MSVC + vcvarsall plumbing for cmake.

To add MSVC-meson kits:

- Extend `compilers.detect` (or a sibling `msvc_kits`-style helper) to
  enumerate VS installations via `vswhere.exe`, the same way
  `detect_msvc_kits` in `cmake_kits.lua` does.
- When the picked tool carries a `vcvarsall` field, the meson module's
  `tasks()` needs to wrap the configure / compile commands so they
  run under the vcvarsall env. Easiest shape: generate a `cmd.exe /c
  "call vcvarsall.bat arch && meson setup ..."` wrapper, the way
  cmake currently does. The wrapper shape should live next to the
  meson task builders, not inside `compose_task_env`, because it
  changes the *command* shape, not just the environment.
- `MesonTestUnit` should prepend MSVC redist DLL locations (the
  per-arch directories under the installation's `VC/Redist/...`)
  rather than a plain `compiler_bin_dir` — MSVC compilers don't ship
  runtime DLLs next to `cl.exe`.

Scope note: this is the reason `cmake` can pick "Ninja + MSVC" today
but `meson` can't. Tracked separately from the gcc/clang support that
already landed.

---

## ~~Strict separation of auto-generated vs user configurations~~

**Addressed** (feature/config-prefix-namespacing + diagnostics work).
Auto-gens are prefix-namespaced (`variant:Debug`, `auto:default-default`),
filtered out of all serialization paths, regenerated every load from
the module. User configs are unprefixed; `:` is banned in user names.
Source-missing stubs are tracked (`_source_missing = true`), preserved
across remerges for graph soundness, GC'd by `update_mapping` when the
last referrer is removed. Stale references surface via `:is_valid()`
on Configuration / ConfigurationSet, aggregated into the status page
Diagnostics section + winbar indicator.

Deferred ergonomics not implemented (revisit if friction shows up):
- `[orphan base]` rebase action — currently a manual edit of `inherits:`
- `Override this config…` shortcut on auto-gen rows
- Self-healing migration that drops user.json entries identical to the
  auto-gen (to collapse pre-prefix bloat)

Supersedes the narrower "[stale] badge for source-missing configurations".

## Plugin-based loomtest adapter discovery

Mirror the existing plugin-based module registry idea: loomtest should
auto-discover test adapters by scanning a conventional directory
(`lua/loomtest/adapters/<name>.lua` on the Neovim runtimepath). Each
file self-registers with `loomtest.register_adapter(...)`. Third-party
plugins can ship new adapters without editing loomtest itself.

Under this pattern, `lua/loomworks/loomtest_adapter.lua` would move to
something like `lua/loomtest/adapters/loomworks.lua` or stay in the
loomworks tree and just follow the same self-registration contract.
Keymaps for `<leader>t*` move out of loomworks entirely — loomtest
ships its own default keymaps.

Prerequisite for eventually splitting loomtest into its own repo
cleanly.

## Pluggable debug adapter architecture

`lua/loomworks/debug.lua` currently hardcodes behavior for nvim-dap and
has static tables of known adapters per language (`DEFAULT_ADAPTERS`,
`KNOWN_ADAPTERS`, `JS_ADAPTERS`). To let new adapters plug in without
editing core — and to give orchestration-heavy adapters (remote
debug-server bridges, on-device protocol bridges) a clean home —
mirror the LSP registry pattern.

### Registry shape

```
lua/loomworks/debug.lua               — dispatcher + registry
lua/loomworks/integrations/debug/codelldb.lua
lua/loomworks/integrations/debug/cppdbg.lua
lua/loomworks/integrations/debug/pwa_node.lua
lua/loomworks/integrations/debug/<vendor>.lua       (third-party)
```

Each integration self-registers:

```lua
require("loomworks.debug").register("codelldb", M)
```

and exposes:

- `M.languages = { "c++" }` — what language keys resolve to this adapter
- `M.build_config(spec, workspace) -> dap_config` — shape the DAP
  config (current `JS_ADAPTERS` transform for pwa-node lives here)
- `M.setup(spec, callbacks) -> teardown_fn|nil` — optional pre-launch
  orchestration (push a debug-server, set up port forwarding, etc.);
  returns a teardown closure invoked on session end
- `M.attach_pid_transform(spec, pid)` — optional, for multi-adapter
  attach to a PID discovered from the primary session
- `M.default_enable = true|false` — whether core auto-picks this
  adapter for its language(s) when user hasn't overridden

### Dispatcher changes

- `M.run(spec, callbacks)` finds the integration by adapter name,
  runs its `setup`, merges the returned config into `dap.run`, and
  registers the teardown on `event_terminated` / `event_exited`.
- `M.resolve_adapter(workspace, language)` reads from the registry
  (iterate integrations whose `languages` contain the key, pick by
  user override then `default_enable`) instead of hardcoded
  `DEFAULT_ADAPTERS`.
- `M.known_adapters(language)` / `M.known_languages()` become
  registry queries. Status page (`ui/sections/debug.lua`) follows.

### Forcing function

The first device-native debug adapter (shipped in a separate plugin)
will be the natural second adapter that validates the design. Land
this refactor first as a pure-internal branch (no behavior change;
existing codelldb/cppdbg/pwa-node tests still pass), then build the
device adapter on top.

### Out of scope here

- Third-party plugin discovery (scanning rtp for integration files) —
  follows the LSP pattern but can wait. First pass: hardcoded
  `require()` list of built-in integrations, same as the original LSP
  refactor's first cut.

## Streaming device scan into picker

Currently `Workspace:scan_devices()` waits for all modules' `list_devices`
callbacks to complete before opening the picker. On slow systems, the
underlying connector tool can take a couple of seconds, leaving the
user staring at "scanning for devices..." before the picker appears.

Ideally the picker would open immediately with results streaming in. This
requires a dynamic-source picker — not supported by `vim.ui.select`.
Options to investigate:
- Use Snacks.picker directly with `source = fun(cb)` or a dynamic items
  mechanism (Snacks is already a hard dependency)
- Cache previous scan results and show them immediately while re-scanning
  in the background, updating the visible list when new results arrive
- Start scans on workspace load so results are cached before the user
  opens the picker

Same treatment would benefit kit/SDK pickers and any other async source.

---

## Disable navigation keymaps in loomworks UI windows

`<C-o>`, `-` (oil.nvim), and similar global keymaps can navigate away
from loomworks status page, config editors, and other UI windows.
Fixed in loomtest explorer — need same treatment in loomworks View/Tree
widget (view.lua, status.lua).

---

## No-tool profile: MSVC auto-detection metadata

When creating a profile without selecting a tool (no cmake kits detected),
cmake picks MSVC automatically. The resulting build is multi-config but
loomworks metadata (cmake_info.multi_config, tool_data.generator) doesn't
reflect this. Investigate why tool detection didn't offer MSVC and why
cmake_info is wrong after configure.

---

## Overseer template references as launch targets

LaunchTarget currently supports module targets (cmake executables) and
command-type configs (loomworks.json launch section). Could also support
referencing overseer task templates (e.g., from VS Code launch.json)
as launch targets.

## Configuration conflict detection

Detect when two configurations share the same output directory (e.g.,
TypeScript outDir). Warn via confirmation dialog before building a
conflicting configuration. Auto-detect from outDir comparison; optionally
allow explicit conflict declaration in loomworks.json.

## Implicit single-config mapping

If a project has exactly one configuration (e.g., TypeScript's "default"),
the configuration_set could omit it — auto-map to the only option.
Reduces loomworks.json verbosity for simple projects.

## Configuration validation

When parsing loomworks.json, validate that configuration_set mappings
reference configurations the module actually knows about. Show warnings
like "ScenePluginTest: 'production' is not a known configuration".

## Optimize redundant npm install

TypeScript configure (npm install) is per-ConfigUnit but npm install is
project-level (shared node_modules). Could deduplicate by making configure
project-level rather than configuration-level.

## ~~Post-build file copy support~~

**Addressed** (feature/deploy-steps). Implemented as deploy steps on launch
configurations — declarative copy steps that ensure build artifacts are
deployed before launch, with freshness tracking. See specification.md
section 9.8.

## TypeScript LSP integration (tsconfig switching)

Similar to clangd integration for cmake: provide factory functions that
route ts_ls/vtsls to the correct tsconfig per profile. Would need a
`typescript.tsconfig` field per configuration in loomworks.json, and a
`ts_ls_root_dir` factory similar to `clangd_root_dir`. Auto-restart
ts_ls on profile switch when tsconfig changes.

Low priority — most TypeScript projects use a single tsconfig.json.
Only needed when profiles map to different tsconfig files (e.g.,
tsconfig.debug.json vs tsconfig.release.json).

## Tool selection when adding second keyed-module type

When adding a project of a *new* keyed-module type (e.g., meson to a
cmake workspace), existing profiles need a tool selection for the new
module type. The multi-tool data model (profile.tools dict) supports
this, but the UI flow for selecting tools per module type during
add-project is not yet implemented. Currently only single-keyed-module
workspaces are fully handled (tool inherited from existing profiles).

## Clear active profile on deletion

When a profile is deleted, the active_profile in loomworks.user.json
should be cleared if it matches the deleted profile. Currently the
profile is removed from cache but user.json still references it,
leaving a dangling active_profile until the user activates something
else.

## Clean directories per configuration

Allow specifying additional directories to delete when cleaning a
configuration. For example, cmake deploy steps copy DLLs and .node files
to `ScenePluginTest/Debug/` — these should be cleaned when the
configuration is cleaned.

Could be defined in loomworks.json per project:
```json
"ScenePluginTest": {
    "typescript": {},
    "clean_dirs": ["${project_path}/Debug", "${project_path}/Release"]
}
```

Variable expansion (${project_path}, ${config_set}) applies. Directories
are deleted during the clean action alongside module clean_tasks.

## Decouple config_key from variant name

Currently `config_key` is derived from `variant + tool_key` (e.g.,
`"Debug:ninja-gcc-12"`). This makes the variant name load-bearing for
identity — renaming a configuration requires rekeying cache entries,
registry slots, and profile configuration arrays.

Ideally, `config_key` would be a stable opaque ID assigned at creation
(e.g., sequential or UUID). The variant name would be purely a display
label. Rename would then be a simple field update with no rekeying.

This would also align with the architectural principle that keys should
not be used for runtime lookups — only direct object references.

## Modules as domain objects + cache deserialization isolation

Modules are currently stateless function tables loaded via `require`.
Making them domain objects would:

1. **Module domain objects** — Workspace owns Module instances. Each
   module owns its Tool registry. `project._module` replaces
   `project.type` string. `tool._module` replaces `tool.mod_type`
   string. Module-specific logic (cmake task generation, info parsing)
   lives on the module object; generic behavior stays in shared code.

2. **Deserialization layer** — The `_sync_*` methods become the only
   place that does key→object resolution. They resolve every string
   reference from cache/config into domain object references, then
   pass fully-resolved data to `_update()`. After deserialization,
   key→object tables are not accessible to domain objects.

3. **No key lookups in domain objects** — `_update()` receives
   pre-resolved references. `_workspace` back-reference either goes
   away or becomes a narrow interface (no registry access). Domain
   objects navigate only via direct references.

This eliminates the remaining string-based lookups: `find_tool(mod_type,
tool_key)`, `mod_type` strings throughout the codebase, and
`_workspace._projects[key]` during `_update()`. Cache format stays
the same (strings on disk, resolved on load). Object identity
preservation and remerge ordering are unchanged.

Entry point: Module domain objects (wrapping existing function tables).

## Built-in sanitizer/tool configuration templates

Provide pre-built abstract mixin configurations for common development
tools: address sanitizer (asan), thread sanitizer (tsan), undefined
behavior sanitizer (ubsan), memory sanitizer (msan). Users inherit from
these mixins to create concrete configs (e.g., `Debug-asan` inherits
`[Debug, asan]`).

Best starting point is the Meson module — Meson has first-class sanitizer
support via `-Db_sanitize=address` etc., so the mapping is clean. For
cmake, sanitizer flags are compiler-specific (`-fsanitize=` for gcc/clang,
`/fsanitize=` for MSVC) and would need compiler detection to generate
correct options. Defer cmake sanitizer templates until compiler-aware
option generation is available.

## Profile/variable persistence lost after task failure

Observed: after creating a profile or adding variables and triggering a
configure/launch that fails, the data may disappear from user.json or
loomworks.json on a subsequent save. Possibly related to the stuck
operation / remerge interaction, or a save triggered by the failure
path overwriting with stale data. Error logging added to `_save_user`
(2026-04-02) to help diagnose if it recurs.

## Variable/deploy discoverability and documentation in UI

The variable system and deploy steps lack in-editor documentation.
Users need help text or descriptions for:
- Available built-in variables (${workspace_root}, ${build_dir}, etc.)
  and what they expand to
- The difference between ${variant} (cmake variant) and ${configuration}
  (config name from profile mapping)
- Source path is relative to build dir (for path type)
- ${project_path} is relative, use ${workspace_root}/${project_path}
  for absolute
- Variable type meanings (string vs path — path enables segment editor)
Could add tooltips, help text in editors, or a help dialog.

---

## ~~Rename-back shows entry in both profiles and orphaned sections~~

**Fixed** (fix/rename-orphan-accumulation). Root cause: rename used
`_rebuild_profile_projects_for` which destroyed and recreated domain
objects. Fix: pure in-place mutation — Configuration, Profile, ConfigUnit
all keep identity. Old BuildDir orphaned as domain object; rename-back
adopts it. Introduced BuildDir domain object, removed `_last_raw_cache`.

---

## Graceful degradation for external dependencies

Current hard dependencies: **overseer** (build/launch), **snacks** (picker,
explorer window). Soft: fidget (progress), nvim-dap (debug), lualine
(status component).

Issues to address:
- **fidget**: build/deploy progress uses fidget exclusively — if not
  installed, progress is silent. Should fall back to `vim.notify` or
  a minimal echo.
- **snacks**: used for `vim.ui.select`-style pickers and the loomtest
  explorer window (`Snacks.win`). Should fall back to `vim.ui.select` /
  `vim.ui.input` for pickers. Explorer window needs snacks or an
  alternative (floating window API directly).
- **overseer**: core dependency, hard to remove. Document as required.
- Audit all `require()` calls to external modules for pcall guards.

---

## codelldb: no local variables for dynamically loaded .node modules

**Symptom**: When debugging a Node.js native addon (.node shared library)
via codelldb (either launching node directly or attaching), breakpoints
and line stepping work but local variables are not shown in scopes.

**Root cause**: LLDB's PDB plugin crashes when trying to resolve symbol
addresses for dynamically loaded modules. `target symbols add` loads
the PDB but hits assertion failure: `obj_load_address != LLDB_INVALID_ADDRESS`
in `SymbolFilePDB::InitializeObject`. LLDB can't determine the load
address of the .node module in memory.

**Findings**:
- PDB files are present and well-formed (function symbols + line tables load)
- `image dump symfile` shows empty Types/Compile units before process runs
- Build uses clang `-g -Xclang -gcodeview` producing CodeView/PDB format
- Standalone cmake executables debug fine with full locals
- Issue is specific to shared libraries (.node/.dll) loaded at runtime
- cppvsdbg (Microsoft's native debugger) would handle this but is
  licensed for VS Code only

**Potential fixes**:
- Switch to DWARF debug info (`-gdwarf` instead of `-gcodeview`) — LLDB
  handles DWARF better for shared libraries
- Wait for LLDB PDB plugin improvements (active development area)
- Structured debug entry with symbol search paths (future loomworks feature)

---

## Plugin-based module registry

Currently modules are hardcoded in `modules/init.lua`. Third-party plugins
should be able to register modules by placing files in `lua/loomworks/modules/`
on the runtimepath. Auto-discovery would scan all rtp entries, validate the
module interface (`M.id`, `M.detect`, `M.info`, `M.tasks`), and register
valid modules alongside built-ins. Needs: interface validation, error handling
for broken modules, load order guarantees, potential config for disabling
specific modules.

---

## Profile-level SDK integration (design ready, not implemented)

**Problem**: Currently profiles select tools per module type independently.
Cross-compilation requires all modules to use the same SDK. Two projects
of different module types in the same profile should be able to share a
single SDK selection.

**Design decisions**:

1. **SDK is a profile-level selection**, not per-module. Profile has:
   - Configuration set
   - SDK (optional domain object reference, nil = host build)
   - Tool overrides (for modules SDK doesn't cover)

2. **SDK provides tools to all modules it supports**. Core asks
   `sdk:query(module.id)` for each module — no module/SDK-specific logic
   in core. If SDK returns nil for a module, that module uses host tools.

3. **No fallback guessing**. If no tool mapping exists for a module in a
   profile, the profile is flagged "incomplete" rather than silently
   creating a default. No automatic Visual Studio / default compiler
   fallbacks. User must explicitly select.

4. **Profile name includes SDK**. "Debug:<sdk>" or "Debug:ninja-clang-18".
   SDK profiles are distinct from host profiles.

5. **Profile creation flow**: pick config set → pick "Host" or an SDK →
   if host, pick cmake kit (existing flow). If SDK, tools derived
   automatically from SDK capabilities.

6. **Serialization**: profile stores `sdk_key` string. Deserialization
   resolves to SDK domain object via workspace. If SDK not found,
   profile is incomplete.

7. **Core stays generic**: no `if sdk_type == "<vendor>"` anywhere. Core
   iterates modules × SDKs via query interface.

**Implementation needed**:
- Profile domain object: add `_sdk` reference field
- Profile creation UI: SDK picker step
- Tool resolution: SDK-first, then module detection, then incomplete
- Remove all tool fallback guessing from modules
- Serialization: sdk_key in user.json profiles section
- Status page: show SDK on profile, incomplete state

---

## UI v2: hardcoded "cmake" fallbacks

Deferred from the incomplete-profile-policy work. UI v1 is the main
interface; UI v2 is still under design. These should be cleaned up
when UI v2 reaches active development, but are not blockers today.

Three call sites silently default to `"cmake"` when the module list
isn't available or zero modules are detected:

- `lua/loomworks/ui/v2/palette.lua:124` —
  `local types = ok and modules.list and modules.list() or { "cmake" }`
- `lua/loomworks/ui/v2/view_model/init.lua:667` —
  `local proj_type = extra and extra.type or "cmake"`
- `lua/loomworks/ui/v2/view/layout.lua:478` —
  `extra = { type = "cmake" }`

Right behavior is to refuse the action with "no project types
available — install or enable a module first" rather than committing
the user to cmake. Will surface noisily once android lands and a user
on a non-cmake codebase tries to add a project from UI v2.

---

## LSP UI: cmake-specific compile_commands hint

Deferred from the incomplete-profile-policy work. Same rationale as
above — UI v1 still mostly drives the experience.

`lua/loomworks/ui/sections/lsp.lua:44`:

```lua
elseif entry.project_type == "cmake" then
    tree:leaf("compile_commands_dir: (not found)", "DiagnosticWarn")
end
```

Hardcodes a "compile_commands_dir not found" warning specifically for
cmake projects. The right shape is for the module's `lsp_configs`
emission to carry an opaque hint flag (e.g.
`expected_compile_commands = true`) and the UI to render that
flag generically. Other modules that ship clangd configs (meson, and
third-party C/C++ modules) are already in the same position; the
pattern just isn't formalised yet.


## Headless CLI: skip an already-done, unchanged configure

`lw build` / `lw test` / `lw run` re-run the module `configure` step on every
invocation. The staleness model (`ConfigUnit:is_stale`, BuildDir option/module
snapshots) is designed for the single-process editor, where the snapshot stays
frozen in memory between a configure and a later config edit. In the headless
CLI each invocation is a fresh process that must reconstruct staleness from the
cache, and wiring `record_task_result` into the headless build path produced
incorrect state (recorded `failed_build` on success) and did NOT detect a
`lw configuration set` option change — so skipping configure would silently miss
config changes. Reverted to always-configure for correctness. A proper fix needs
the load path to reliably populate `_cached_options` / `_cached_module_config`
from the cache and freeze them across processes. The re-configure is a fast
near-no-op (`cmake` reconfigure / `meson setup --reconfigure`).
