# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Phase 2: Target launching & process management

- `Target:launch()` — run built artifact via overseer
- cmake `launch_target_task()` — constructs command from artifact path
- LaunchTarget types: overseer template references, custom commands
- Launch args, env, working_dir fields on LaunchTarget
- `<F5>` / `<leader>wr` — build then launch
- `<S-F5>` — kill running process
- Auto-open overseer for launch tasks
- Process tracking (which launched task is running)

## Overlapping profile operations

When user triggers build while configure is still running, the second
`start_operation()` clobbers the first operation state. Fidget handle
gets finished prematurely. Need operation queuing or stacking.

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

## ConfigUnit listener accumulation

`on_state_change` listeners on ConfigUnit accumulate and are never cleared.
If `launch_tasks()` deferred builds register listeners repeatedly, they
pile up. Consider clearing listeners on state transitions or using a
one-shot pattern.
