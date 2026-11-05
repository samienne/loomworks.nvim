# loomworks.nvim — Project Context for Claude

## What this is

The Neovim plugin of loomworks: a thin client of the `lw` workspace daemon.
It keeps the daemon client, the UI, loomtest, the LSP/DAP integrations, the
provisioning of the managed `lw` and its Lua bundle, and a few files vendored
from loomworks. The daemon, the `lw` CLI, the modules, the SDK providers and
the workspace engine live in **samienne/loomworks** (local checkout
`C:/src/loomworks`, its own spec and workflow). The plugin holds no workspace
model and never builds, detects toolchains or removes build directories
itself; protocol-only coupling, no plugin-side fallbacks.

The plugin lives at `C:/src/nvim-plugins/loomworks.nvim` and is loaded via the
owner's Neovim config (C:/Users/samie/AppData/Local/nvim, branch `loomworks`),
which auto-loads every subdirectory of `C:/src/nvim-plugins` as a lazy.nvim dev
plugin.

## Authoritative Documents

- **[spec/plugin.md](spec/plugin.md)** — the plugin's one normative spec.
  Part I the editor client (§9 LSP, §13 auto-load, §14 commands, §18.11,
  §19.16 the editor as a client incl. the managed `lw` and bundle), Part II
  the UI (status page, highlights, statusline; local numbering). The core
  contract (core §1–§8, §10–§12, §15–§19) lives in loomworks'
  [`spec/core/`](https://github.com/samienne/loomworks/blob/main/spec/core/README.md),
  the module specs in its `spec/modules/` and the SDK spec in its
  `spec/sdks/`; plugin.md links them as "loomworks core §N" — not
  requirements on this plugin; change them in loomworks, not here.
- **[spec/integrations/](spec/integrations/)** — per-integration specs:
  `lsp/` (clangd, qmlls), `debug/` (codelldb, cppdbg, pwa-node).
- **[spec/protocol/](spec/protocol/)** — VENDORED from loomworks
  (`PROTOCOL.md`, `API.md`, schemas). Never edit here; see Vendoring.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how the plugin is built: layers,
  `lua/` layout, data flow, provisioning, vendoring, tests.
- **[README.md](README.md)** — user-facing: install, setup options, commands,
  keymaps.
- **[LOOMTEST.md](LOOMTEST.md)** — the loomtest test explorer.
- Daemon side: loomworks' `spec/protocol/PROTOCOL.md`, `spec/protocol/API.md`,
  `spec/formats.md`, `ARCHITECTURE.md`.

Do NOT duplicate content from these files in CLAUDE.md. Refer to them instead.

## Spec-First Development Workflow

**Before implementing any change that contradicts spec/plugin.md (Parts I–II)
or ARCHITECTURE.md, STOP.** Propose the spec change first, explain the
reasoning, and wait for approval. Only after approval update the spec (and
ARCHITECTURE.md if the structure changes), then implement.

1. Identify what needs to change (spec vs current behavior)
2. Propose a spec amendment (show the diff or describe the change)
3. Wait for user approval
4. Update spec/plugin.md (and ARCHITECTURE.md if architecture changes)
5. Implement the code change
6. Update or add tests

Changes clearly within the spec (bug fixes, tests, refactoring without
behavior change) skip steps 1-4. A change to the protocol, the daemon or the
engine belongs in loomworks, not here.

## Vendoring

Files listed in `VENDOR.MANIFEST` (`spec/protocol/**`, `lua/loomworks/proto/*`
and a few shared modules) are byte-identical copies of a loomworks release.
Never edit them here: change the file in loomworks, tag, run
`scripts/vendor.sh`; `scripts/vendor.sh --check` verifies.

## Branch Workflow

All changes go through branches — never commit directly to master.

### Plan first, then execute

Before starting implementation, propose a plan and wait for approval. This
applies to non-trivial changes — simple one-line fixes or obvious corrections
can proceed directly.

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

1. **spec/plugin.md** — all behavioral changes are reflected
2. **ARCHITECTURE.md** — any structural changes are documented
3. **README.md** — user-facing changes are covered
4. **No discrepancies** — the three documents agree with each other and with
   the code being merged
5. **Type annotations** — all LuaCATS `@class`/`@field` annotations affected
   by the changes are up to date
6. **Comments** — comments near changed lines are still accurate
7. **Vendored files** untouched (`scripts/vendor.sh --check`)
8. **Tests pass** — `make test` (runs against the pinned `lw`, provisioned
   into `.lw-test/`)
9. **CHANGELOG.md** — user-visible changes are under `## Unreleased`, in the
   right section, with the PR number

**Do not merge if documentation is out of sync.** Fix the docs first, then
merge. If the user does not ask for this check, remind them before merging.

### Bugfix workflow

When a bug is encountered, reproduce it with an integration test first,
then fix it.

1. Write a failing integration test that reproduces the bug
2. Verify it fails for the right reason
3. Fix the bug
4. Verify the test passes

### Merge format

Use `git merge --no-ff` with a summary commit message that describes *what*
and *why* — not a dump of individual branch commits.

## Deletion Safety (mandatory review)

The plugin deletes only what its provisioning creates. Any change that touches
deletion logic in `lua/loomworks/provision/` (`cache.prune`, the `.dl` temp
file of `fetch.ensure`, the bundle staging of `bundle.lua`) **must** be
reviewed for directory safety before merging:

1. **Boundary check**: path prefix comparisons include a trailing `/`
   separator (`/root` must not match `/roots/...`): `path == prefix or
   path:sub(1, #prefix + 1) == prefix .. "/"`.
2. **Plugin-managed lw** (spec §19.16): `provision/cache.prune` runs only with
   a wanted hash and no download in flight; removes only `<64 lowercase hex>`
   entries of `<stdpath data>/loomworks/lw` (itself lstat-real) that are real
   directories (lstat; links/junctions skipped, never followed) whose realpath
   is a direct child of that dir's realpath (separator-bounded), holding only
   the regular file `lw`/`lw.exe`: unlink it, then `rmdir` (no rm_rf). Never
   the wanted hash, a binary in use (launched, observed, live handle `exe`,
   by path or realpath), nor a slot whose directory mtime (its last use) is
   younger than `cache.UNUSED_S` (14 days). `fetch.ensure` only unlinks its
   own `<sha256>.<pid>.<n>.dl` path (a file or link, never a directory; never
   written through) and renames over a slot binary whose hash mismatches;
   prune removes another pid's regular `.dl` file after 24 h. **Pruning is
   paused** (samienne/loomworks#101): keep it off until that issue is
   resolved, and re-review these rules when it is re-enabled.
3. **Managed bundle** (spec §19.16): the editor removes only its own `.dl`
   file and its own staging directory `.stage-<sha256>.<pid>.<n>` — that exact
   path, which must be a real directory (lstat; not a link/junction) directly
   under `<stdpath data>/loomworks/bundle/`. Links inside it are unlinked,
   never followed. No bundle slot (`bundle/<sha256>/`) is ever removed.

## Implementation Notes

- **Thin client**: `init.lua` is the public facade; the editor holds no
  workspace model. Reads go through the sources (`status_source`,
  `lsp_source`, `test_source`, `device_source`) over `views.lua`; writes go
  through `ui/model_calls` and `daemon/editor_ops` / `daemon/facade`. No UI
  or integration file talks to the connection directly.
- **One connection per workspace**: `daemon/observer.lua` over the `--stdio`
  relay (`daemon/client/relay.lua`). Degraded state with a reason when no
  usable `lw`/daemon; no in-process fallback.
- **Tasks**: every daemon task is one overseer task (`daemon/task_runner.lua`);
  the editor's own overseer tasks are only a launched program and a device log
  stream (`task_launch.lua`).
- **LSP integrations outside core**: the daemon's `LspConfig/1` is read via
  `lsp_source`; server wiring lives in `integrations/lsp/<server>.lua`.
- **DAP** (`debug.lua`): adapters resolved by language; `session_tracker.lua`
  runs build → deploy → launch/debug.
- **loomtest** (`lua/loomtest/`): independent of loomworks;
  `loomtest_adapter.lua` serves the daemon's `view.Tests/1` / `Tests/1`.
  neotest only refuses (`neotest/init.lua`).
- **Provisioning** (`provision/`): `select` → `probe` → managed slot via
  `fetch` and `bundle`; the pin is `provision/pinned.lua`
  (`scripts/release/pin.sh`).
- **Windows paths**: compare normalized paths; atomic renames may need a retry
  when the target is open.
- **`:LoomworksReload`** (`reload.lua`) is a dev hatch: shutdown, then
  `lazy.reload`.
