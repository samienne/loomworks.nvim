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

