# loomworks.nvim — Project Context for Claude

## Authoritative Documents

- **[specification.md](specification.md)** — Behavioral specification. Defines
  *what* the system does: data model, state machines, UI behavior, invariants.
  This is the single source of truth for behavior.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Implementation architecture. Defines
  *how* the system is built: layers, object model, data flow, file layout.
- **[README.md](README.md)** — User-facing documentation. Setup, API, examples.

Do NOT duplicate content from these files in CLAUDE.md. Refer to them instead.

## Spec-First Development Workflow

**Before implementing any change that contradicts what is written in
specification.md or ARCHITECTURE.md, STOP.** Propose the specification change
first, explain the reasoning, and wait for approval. Only after the spec
change is approved should you update specification.md and then implement the
code change.

This prevents the spec and implementation from diverging. The cycle is:

1. Identify what needs to change (spec vs current behavior)
2. Propose a spec amendment (show the diff or describe the change)
3. Wait for user approval
4. Update specification.md (and ARCHITECTURE.md if architecture changes)
5. Implement the code change
6. Update or add tests

For changes that are clearly *within* the existing spec (bug fixes, adding
tests, refactoring without behavior change), skip steps 1-4 and implement
directly.

## Branch Workflow

All changes go through branches — never commit directly to master.

### Commits

Do not create commits automatically. Only commit when the user explicitly
asks. It is fine to suggest "should we commit this?" at natural stopping
points.

### Creating branches

- **Feature branches**: `feature/<short-name>` — new functionality or enhancements
- **Bugfix branches**: `fix/<short-name>` — bug fixes
- Branch from master. Multiple commits on the branch are fine.

### Mid-feature bugfixes

If a bug is discovered while working on a feature branch:

1. Switch to master, create `fix/<name>`, fix and merge `--no-ff`
2. Switch back to the feature branch, rebase onto updated master
3. Resolve any conflicts

### Pre-merge checklist (mandatory)

Before merging ANY branch to master, verify:

1. **specification.md** — all behavioral changes are reflected
2. **ARCHITECTURE.md** — any structural changes are documented
3. **README.md** — user-facing changes are covered
4. **No discrepancies** — the three documents agree with each other and with
   the code being merged
5. **Tests pass** — `make test`

**Do not merge if documentation is out of sync.** Fix the docs first, then
merge. If the user does not ask for this check, remind them before merging.

### Merge format

Use `git merge --no-ff` with a summary commit message that describes *what*
and *why* — not a dump of individual branch commits.

## What this is

A Neovim workspace management plugin. Provides project structure information
to other plugins (LSP configs, overseer, DAP). Non-invasive — collaborators
don't need to know it exists. Read-only toward project files.

The plugin lives at `C:/src/nvim-plugins/loomworks.nvim` and is loaded via the
owner's Neovim config (C:/Users/samie/AppData/Local/nvim, branch `loomworks`),
which auto-loads every subdirectory of `C:/src/nvim-plugins` as a lazy.nvim dev plugin.

## Key Concepts (quick reference)

- **workspace** — top-level unit, defined by `loomworks.json`
- **project** — sub-component with a type (cmake, ets, typescript)
- **configuration** — build variant within a project (Debug, Release)
- **configuration_set** — cross-project mapping of configurations
- **tool** — module-specific toolchain (cmake: generator+compiler)
- **profile** — fully resolved buildable unit (configuration_set + tool)
- **ConfigUnit** — single source of truth for (project_key, config_key) runtime state

See specification.md sections 1.1–1.7 for full definitions.

## Implementation Notes

These are implementation-specific details not covered by the spec or architecture:

- Constructor pattern: `Core.new(deps)` with injectable dependencies for testing
- Generation counter: `Core._generation` increments on remerge, objects detect staleness
- `types.lua` defines LuaCATS type annotations (data shapes, not runtime code)
- init.lua is thin facade; core.lua holds business logic; status.lua is pure rendering
- Progress tracking: ninja parser, operation timing, weighted aggregate
- Atomic writes on Windows: rename can fail if file is open; implement retry with short sleep
- clangd auto-reloads when compile_commands.json changes on disk — no explicit restart needed

## v1 Scope

**V1 modules:**
- `cmake` — full implementation
- `ets` — shim (shows project exists, no build functionality)
- `typescript` — shim (shows project exists, no build functionality)

**Deferred (not in v1):**
- Meson module, DAP, test integration, sub-workspaces, cross-project
  dependencies, auto-detection, named toolchains — see specification.md for
  interface stubs where applicable.
