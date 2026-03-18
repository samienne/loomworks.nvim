# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Overseer template references as launch targets

LaunchTarget currently supports module targets (cmake executables) and
command-type configs (loomworks.json launch section). Could also support
referencing overseer task templates (e.g., from VS Code launch.json)
as launch targets.

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

## Post-build file copy support

Some projects need files copied after build (e.g., cmake-built native
libraries copied to TypeScript project's Debug/Release folder). Need a
post-build step or copy-file mechanism in loomworks.json.

## Fidget spinner stuck on workspace load failure

When loomworks.json parsing fails (e.g., "multiple type keys" error), the
"loading workspace" fidget spinner stays indefinitely. The initialization
event flow doesn't emit completion on parse failure.

## UI status should show "cleaning" instead of "deleting" for clean action

When cleaning a configuration, the UI shows "deleting" state. Should show
"cleaning" instead. Either add a separate ConfigUnit state or map the
display label based on the action that triggered the deletion flag.

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

## Profile build triggers builds for unrelated configurations

Reported on LumeTS workspace with ninja+clang. Building a profile
triggered Debug, RelWithDebInfo and Release builds from an unrelated
profile, and created orphaned configurations for an unused tool.
Ninja is single-config so cmake tasks() should only generate one build
task. Need to reproduce and investigate — may be related to
has_keyed_tools removal, ProfileProject config_key computation, or
task collection logic.

## MSVC builds fail when Neovim shell is Git Bash

**Root cause confirmed**: When `vim.o.shell` is set to Git Bash, MSVC
builds fail even though wrap_cmd uses `{ "cmd", "/C", ... }`. The bash
parent process environment is inherited — PATH includes mingw paths
that interfere with MSVC toolchain. Builds work fine in a cmd.exe
terminal.

**Fix options**:
1. Write a temp .bat file and execute it — gives cmd.exe a clean env
2. Use `vim.fn.jobstart` with `env` option to override PATH
3. Strip mingw paths from PATH before spawning MSVC builds
4. Document that users should not set vim.o.shell to bash on Windows
   (least desirable — user's terminal manager needs it)

Option 1 (temp .bat file) is the most robust. The .bat file would
contain the vcvarsall call and cmake command, executed by cmd.exe
directly.

## Deleting orphaned configurations from UI broken

The delete action on orphaned configurations in the status page doesn't
work. Needs investigation — may be related to the object model refactoring
or the flat cache format change.

## ConfigUnit listener accumulation

`on_state_change` listeners on ConfigUnit accumulate and are never cleared.
If `launch_tasks()` deferred builds register listeners repeatedly, they
pile up. Consider clearing listeners on state transitions or using a
one-shot pattern.
