# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Overseer template references as launch targets

LaunchTarget currently supports module targets (cmake executables) and
command-type configs (loomworks.json launch section). Could also support
referencing overseer task templates (e.g., from VS Code launch.json)
as launch targets.

## user.json version check

Add version validation for `loomworks.user.json` like cache.json has.
On mismatch, refuse to load (use defaults). Show warning in status page
with option to delete the user config.

## Configuration conflict detection

Detect when two configurations share the same output directory (e.g.,
TypeScript outDir). Warn via confirmation dialog before building a
conflicting configuration. Auto-detect from outDir comparison; optionally
allow explicit conflict declaration in loomworks.json.

## Module clean_tasks integration

`clean_tasks()` is defined on the TypeScript module but not yet consumed
by core. Wire it up:
- Clean action (C key): run module clean_tasks before resetting cache state
- Rebuild: change from delete+build to clean+build

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

## Fidget spinner stuck on workspace load failure

When loomworks.json parsing fails (e.g., "multiple type keys" error), the
"loading workspace" fidget spinner stays indefinitely. The initialization
event flow doesn't emit completion on parse failure.

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

## Unify clean/delete under Operation model

Clean and delete actions use separate machinery (`_deleting` flag,
`_queued_action`, `deletion_started`/`deletion_completed` events,
separate fidget handles) instead of the Operation class used by
build/configure. Unifying would give:

- "cleaned in 3s" / "deleted in 5s" as last-operation messages
- Natural queuing: build waits for clean to finish via Operation
  watching, replacing the ad-hoc `_queued_action` mechanism
- Single fidget handle model (per-Operation, not separate `del:` keys)

Semantics: clean/delete should stop running build/configure immediately.
Build/configure issued during clean should queue (wait for clean to
finish, then proceed). The `_deleting` flag and crash-safety flow
(`unknown` state before async deletion) must be preserved.

## ConfigUnit listener accumulation

`on_state_change` listeners on ConfigUnit accumulate and are never cleared.
If `launch_tasks()` deferred builds register listeners repeatedly, they
pile up. Consider clearing listeners on state transitions or using a
one-shot pattern.
