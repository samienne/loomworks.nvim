# loomworks.nvim — Specification

This document is the authoritative behavioral specification for loomworks.nvim.
It defines *what* the system does — data model, state machines, integration
contracts, and invariants — not how it is implemented. The implementation
(code) and architecture (ARCHITECTURE.md) must conform to this specification.

## Document layout

This file is the **index** over the core specification. The core spec
describes contracts and behavior that hold for any module, LSP integration,
DAP integration, or SDK provider. It does not name specific modules, tools,
compilers, or SDKs in normative prose. Its normative sections have been
physically partitioned into topic files under [`spec/core/`](spec/core/) —
this file keeps the preamble, the routing tables, and **§15 Invariants**
(the global cross-cutting contract) inline; every other section lives in a
`spec/core/*.md` file. The split is physical only: section numbers are
never renumbered, and no top-level `§N` is ever split across two files.

**Core specification — section range → file:**

| Sections | Topic | File |
|--|--|--|
| §1 | Data Model | [`spec/core/data-model.md`](spec/core/data-model.md) |
| §2 | Three-File Model | [`spec/core/three-file-model.md`](spec/core/three-file-model.md) |
| §3–§7 | State & Lifecycle (state machine, profile lifecycle, task execution, UI, events) | [`spec/core/state-lifecycle.md`](spec/core/state-lifecycle.md) |
| §8 | Module Interface | [`spec/core/module-interface.md`](spec/core/module-interface.md) |
| §9–§14 | Integrations (LSP, SDK, device, overseer, auto-load, commands) | [`spec/core/integrations.md`](spec/core/integrations.md) |
| §15 | Invariants | this file (`specification.md`) |
| §16 | Headless / Standalone Execution | [`spec/core/headless.md`](spec/core/headless.md) |

Implementation-specific specs live in sibling files under `spec/`:

- [`spec/modules/`](spec/modules/) — per-module implementations (cmake,
  meson, shell, typescript)
- [`spec/integrations/lsp/`](spec/integrations/lsp/) — per-LSP-server
  integrations (clangd, …)
- [`spec/integrations/debug/`](spec/integrations/debug/) — per-DAP-adapter
  contracts (codelldb, cppdbg, pwa-node, …)
- [`spec/sdks/`](spec/sdks/) — per-SDK-provider details (cpp_compiler, …)
- [`spec/ui.md`](spec/ui.md) — the status page, highlight groups, and
  winbar/statusline component

Section numbering differs by subtree. The `spec/core/*.md` files are a
physical partition of the single global core §-namespace: they keep their
**original** section numbers (§1, §2, …, §16) and do **not** restart at §1.
By contrast, section numbers inside the other `spec/` subtrees
(`spec/modules/`, `spec/integrations/`, `spec/sdks/`, `spec/ui.md`) are
local to each file and restart at §1.

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

