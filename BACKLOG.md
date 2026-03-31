# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

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

## Post-build file copy support

Some projects need files copied after build (e.g., cmake-built native
libraries copied to TypeScript project's Debug/Release folder). Need a
post-build step or copy-file mechanism in loomworks.json.

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

---

## Rename-back shows entry in both profiles and orphaned sections

After renaming a pinned single-config "Debug" → "Development" (orphan
appears correctly), then renaming back "Development" → "Debug", the
entry appears in both the profiles section (configured) and the
orphaned section (configured). The cache entry linking during PP
rebuild works (state restored), but orphan detection still sees the
entry. Likely a `_last_raw_cache` staleness issue or a mismatch
between ConfigUnit.id and the cache entry key. Investigate after the
two-layer-config refactor stabilizes.

