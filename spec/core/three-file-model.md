> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 2. Three-File Model

All three files are JSON written **deterministically**: object keys in sorted
order at every depth (arrays keep their order), so rewriting unchanged data
produces byte-identical output and an edit shows up as a minimal diff.

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
- Never trusted to name programs: program-bearing fields (§17.6) in it are
  ignored with a diagnostic, and preserved when the user publishes.
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
  "_meta": { "version": 2, "written_by": "0.1.43" },
  "name": "reactive",
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "configuration_set_descriptions": { ... },
  "profiles": { ... },
  "intent": { ... },
  "default_target": { ... },
  "device": { ... },
  "profile_variables": { ... },
  "lsp": { ... }
}
```

The `device` field maps profile keys to device serial strings:
```json
"device": {
    "Debug:<sdk>-<platform>-<arch>": "FMR0225108000951"
}
```
It is unrelated to a project's `device` block (`projects.<p>.<type>.device`,
§18.9), which shapes remote execution and lives in the project definition.

The `profile_variables` field holds each profile's machine-local fill values
for **blank** project variables (§1.3.1), keyed profile → project → variable:
```json
"profile_variables": {
    "Debug:ninja-gcc-12": {
        "App": { "sdk_root": "/opt/sdk/3.2" }
    }
}
```
These are per-machine values (an SDK path, a device address) and — like the
`active_profile`, `name`, and `device` fields — are personal to this checkout:
they live in `user.json` only and are never published to `loomworks.json`
(§2.4), regardless of the profile's intent. The reserved `cache` policy variable
(§1.3.2) is filled through this same map when a profile pins a machine-local
compiler-cache policy; its *configuration-* and *compiler-family-level*
overrides, by contrast, live in the project's `variables` / `overrides` blocks
and publish and merge per-variable exactly like any other variable value
(§2.3 per-configuration merge).

The optional `name` field overrides the workspace display name (§1.1). It is
present only when the user has set one explicitly (`lw init --name`,
`lw workspace rename`, or the editor); when absent the name defaults to the
root directory basename. Written to `loomworks.json` on publish.

The `intent` field stores explicit per-item intent overrides (see §2.4).

The `configuration_set_descriptions` field holds configuration-set descriptions
(§1.10), keyed by set name. It has the same shape and meaning as in
loomworks.json. A set's entry lives in whichever files the set itself lives in.
Descriptions of projects, configurations and profiles sit inside those items'
own tables (§1.10).

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
  A save never overwrites a working copy another process changed since this
  one last read it: it is refused and the working copy reloaded (§2.7).
- Signed with the machine key (§17.3); used only when the signature is valid —
  an unsigned or modified working copy is refused until the user trusts or
  discards it (§17.4). It is the only file whose program-bearing fields
  (§17.6) are honored.
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

The exact glyph is a UI-spec choice (see `spec/ui.md`).
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

#### Descriptions

A description (§1.10) is part of its item's **content**, never an item of its
own. It has no intent of its own and follows every rule of this section with
its item:

- **Where it is written.** Exactly the files the item is written to:
  - a `local` item's description stays in user.json;
  - a published item's description is published with it;
  - a `shared` item's description is read from loomworks.json and shown
    dimmed like the rest of the item.

  A configuration set's sidecar entry (`configuration_set_descriptions`) is
  serialised alongside the set. It is written, removed, published and reverted
  with the set, including by per-item publish, which leaves other sets' entries
  in the file as they are.
- **Editing is use.** Setting or clearing the description of a `shared` item
  materialises it (implicit cascade on use, above) exactly like any other edit.
  A description never changes an item's intent.
- **Modified indicator.** A description change is a content change. An item
  whose effective intent includes `shared` and whose description differs from
  the baseline shows `+`. Comparisons use normalised text (§1.10), so a
  difference only in line endings or trailing whitespace is not a change.
  For a configuration set, the comparison covers its mappings **and** its
  sidecar entry. For a profile, it covers the published profile definition
  including `description`. For a launch configuration, it covers the launch
  table, whose `description` is compared normalised. A launch change shows on
  its project, as every launch change does today.
- **Merge.** The per-key merge rules above apply unchanged:
  - A project's description is a project-level field. It comes from user.json
    when user.json declares the project, otherwise from loomworks.json.
  - A configuration's description comes with the winning configuration table
    (user wins per configuration name).
  - A configuration set's and a profile's description come with the winning
    set or profile, which are atomic per name.
  - A launch configuration's description comes with the winning launch table
    (user wins per launch name).

  A user.json item never inherits a description from its loomworks.json
  counterpart field by field: the winning item's description, or its absence,
  wins.
- **External changes (auto-sync).** The "content matched the old baseline"
  test includes the description. An untouched item picks up an upstream
  description change, and an item whose description the user edited keeps it.
  For a project, the auto-synced project-level fields are `path`, `type`,
  `depends_on` and `description`.
- **Revert.** `:e!` and per-item revert restore the baseline description. When
  the baseline has none, they remove the item's description.
- **Pull.** A working-copy pull (§16.25) carries each pulled item's
  description, including a set's sidecar entry. The rule is the same
  source-wins rule as the rest of the item.

#### Saving (`:w`)

`:w` on the status buffer regenerates loomworks.json from the working copy:

- For every item with effective intent including `shared`, write current
  content to loomworks.json.
- Items previously in the published baseline whose effective intent no
  longer includes `shared` are removed from loomworks.json.
- After write, the published baseline is updated to match the new
  loomworks.json. `+` and removed-upstream indicators clear.

A profile's **fill values** for blank project variables (§1.3.1) are
per-machine working-copy state, not a publishable item: they are excluded
from `:w` and never reach loomworks.json even when the profile that owns them
is published.

The same serialization is available read-only: an **export** (§16.39) prints
what `:w` would write, or the whole workspace as if every item were
`local+shared`, without writing any file or changing any intent. An
**import** (§16.39) replaces the working copy from such a file. An item the
working copy already holds keeps its intent; a new item gets its intent by
presence in the current published snapshot. So it never alters what is
published.

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
  "_meta": { "version": 8, "cached_at": "...", "written_by": "0.1.43" },
  "build_dirs": {
    "build/App/ninja-gcc-12/Debug": {
      "project_key": "App",
      "config_key": "Debug:ninja-gcc-12",
      "type": "cmake",
      "state": "built",
      "variant": "Debug",
      "build_dir": "/workspace/.nvim/build/App/ninja-gcc-12/Debug",
      "last_configured": "2026-03-10T12:00:00Z",
      "last_built": "2026-03-10T12:05:00Z",
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "cmake": { "generator": "Ninja", "compiler": "GCC 12.3" },
      "artifacts": [
        "/workspace/App/bin/app.exe",
        "/workspace/App/bin/app.pdb"
      ],
      "overwritten_by": "build/App/ninja-clang-17/Debug"
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
- Signed with the machine key (§17.3). An unsigned cache (an earlier loomworks)
  is ignored and replaced by the next cache write (loading never writes it);
  one with an invalid signature refuses the load
  until reset (§17.4). Its `tool_data` is a record only — executable paths come
  from detection (§17.7).
- Never auto-removes entries — survives git branch switches intact.
- Grows as builds happen; shrinks only on explicit delete/clean.
- Flat `build_dirs` dict keyed by the config unit's **relative build-dir
  path** (`unit.id` / `bd.rel_path`, e.g. `build/App/ninja-gcc-12/Debug`; an
  external build system's key is its absolute path). Each entry is
  self-describing (includes `project_key`, `config_key`, `type`, `variant`,
  and tool properties), so it stands alone without a separate profiles table
  — a profile's cache linkage is the set of build-dir keys its config units
  resolve to.
- `deploy_state` dict keyed by normalized absolute destination path. Tracks
  which source config unit's artifact was last deployed to each destination.
  Cleaned when source config units are deleted/cleaned.
- `device_sync` — per device serial → staging root, the §18.4 incremental-sync
  record (runtime state; compacted on load).
- `artifacts` — the config unit's **resolved artifact set**: the absolute
  on-disk output paths its last successful configure resolved, via the
  module's `resolve_artifacts` (§8.4). Stored in **display** casing, exactly
  as `build_dir` is; the normalized forms used for cross-unit comparison are
  derived at runtime (the `_artifact_refs` index, §5.9) and never persisted.
  These fields are additive and optional at the current cache version — no
  version bump — because absence reads back as prior behavior. Present
  **only after a successful configure**: a never-configured unit has no
  `artifacts` field at all (unknown-until-configure — never an empty-array
  guess), and a module that does not implement `resolve_artifacts` likewise
  writes no field. Such units take no part in conflict detection (§5.9).
- `overwritten_by` — present when another config unit has built over one of
  this unit's shared artifacts (§5.9), marking this unit's `built` state no
  longer trustworthy. Its value is the **cache key of the overwriting unit** —
  the same relative build-dir path (`unit.id`) that keys the `build_dirs` dict
  (e.g. `build/App/ninja-clang-17/Debug`). Present only while the condition holds: the
  field is absent when the unit is not overwritten, and is dropped on the next
  save when the unit rebuilds or a resync finds the two units no longer share
  an artifact. An `overwritten_by` pointing at an entry no longer in the cache
  is ignored on load (treated as clear), consistent with the cache's
  orphan-tolerant, descriptive-not-prescriptive stance (§2.5).
- Both fields are **success-path** state — `artifacts` is written after a
  successful configure, `overwritten_by` after another unit's successful
  build — so neither participates in the "cache reflects unknown state before
  async work begins" rule that guards destructive operations (deletion/clean):
  there is no pre-async placeholder to write. Deleting or cleaning a unit
  removes its whole entry, taking both fields with it.
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
- A save merges with a cache another process changed since this one last read
  it, per entry, so concurrent processes never lose each other's build records
  (§2.7).

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

### 2.7 Concurrent writers

Any number of loomworks processes may hold the same workspace open and write
its `.nvim/` state at the same time: the editor, any number of CLI
invocations, a long-lived background process, and **older** loomworks versions
(an older editor plugin, a repository pinned to an older release, §16.21). Each
writes whole files atomically (§15 invariant 4) and reconciles the others'
writes as external changes (§2.4 "External changes", §2.3), but a process only
notices another's write on its next reconciliation. A save is therefore never a
blind overwrite of the working copy or the build cache: it is guarded as below.
(`loomworks.json` is regenerated only on an explicit publish, §2.4, and is not
guarded.)

**Disk baseline.** Per guarded file (working copy, build cache) each process
remembers the **exact bytes** it last read from disk — at load, or when it
reconciled an external change — or last wrote itself; "absent" is a baseline
too. Before overwriting the file, the process re-reads it; if the bytes differ
from its baseline, the file changed since this process last saw it, and the
save is **stale**. The fingerprint is the full content, not a timestamp or a
counter: modification times are coarse on some file systems and a same-size
rewrite within one tick is invisible to them, and a counter stored in the file
would be dropped or reset by an older version that rewrites the file without
knowing it — exact content detects every foreign write, including those. The
files are small enough that the extra read is negligible. A process's own
consecutive saves never appear stale: each write moves its baseline to the
bytes it wrote.

**Build cache: merge.** A stale cache save is merged, not refused, so another
process's build record is never lost. The process reads the disk cache
(verified as in §17.4) and merges per **entry** of the cache's keyed maps
(`build_dirs`, `deploy_state`, `device_sync`):

- an entry this process **changed** since its last sync with disk — its
  serialization differs from the one it had when it last read or wrote the
  file; this includes entries it added or removed — is taken from this
  process;
- every other entry, and every top-level member this version does not write,
  is taken from disk (another process's additions, updates and removals
  survive).

The merged cache is written, and the process then reconciles its in-memory
state to it exactly as it would an external change (another process's units
appear built, configured, reset, …). When both processes changed the **same**
entry, this process wins; build-state changes to one build directory are
already serialized by the per-build-directory lock (§16.6), so this only
arises for bookkeeping that is safe to repeat. A cache that another process
deleted (a reset of the whole cache) merges as an empty one: only this
process's own changes are written back. A disk cache that is unsigned is not
read — this process's cache is written as is, as for any unsigned cache change
(§17.4); one with an invalid signature or a newer schema is not overwritten —
the save is refused (reported as for the working copy below) and the change,
once reconciled, puts the workspace in the refused state (§17.4, and "Reading a
newer file" below).

**Working copy: refuse and reload.** A stale working-copy save is **refused**:
nothing is written, the process reloads the working copy from disk (as an
external change, §2.4, verified per §17.4) — its own unsaved change is
discarded — and reports:

```
the working copy (.nvim/loomworks.user.json) changed on disk (another lw or editor) — reloaded it; your last change was not saved, redo it
```

The editor shows it as an error notification; the CLI prints it as
`lw: …` and exits **1**. Item-level replay is deliberately not attempted:
working-copy mutations are not independent per item — a rename propagates
through configuration sets and profiles, use materializes referenced items
(§2.4 implicit cascade), and the file must stay self-contained (§2.2) — so
splicing one process's changed items into another's file can produce a working
copy neither intended (a profile naming a set the other process removed).
Refusing keeps both on-disk states intact; redoing a change is cheap, and the
window in which it can happen is a few seconds of concurrent editing.

**Write lock.** The re-read, the merge and the write happen under a short-lived
per-file advisory lock: an exclusive create (`O_EXCL`) of
`<file>.lock` beside the file, held only for that step (milliseconds). A
process that finds the lock held retries for a bounded time (about two
seconds). A lock whose file is older than a short stale window (a few seconds —
far longer than any save) belongs to a crashed holder and is reclaimed by an
atomic rename, as for the build-directory lock (§16.6). If the lock is still
held when the retry time runs out, the save proceeds without it — the stale
check still applies — rather than lose the change. A process removes only a
lock it still owns.

**Remaining race.** There is no cross-process compare-and-swap for a rename, so
the guard is advisory. A writer that does not take the lock — a loomworks
version before this section, or a hand edit — can still write between this
process's re-read and its rename (a window of milliseconds), and that write is
then overwritten, as every write was before this section; so can a writer that
gave up waiting for the lock. Writers that follow this section exclude each
other completely.

**Writer version stamp.** Every write of the working copy and of the build
cache records, besides the schema version `_meta.version`, the writing
loomworks version as `_meta.written_by` (a development build records its last
released version with a `+dev` suffix; precedence ignores the suffix; a build
that cannot tell its version records none). In the
working copy `_meta` is part of the signed bytes (§17.3). Older versions read
only `_meta.version`, ignore unknown `_meta` members and rewrite `_meta`
without them; a file without `written_by` was written by such a version.

**Reading a newer file.**

- **Newer schema** — `_meta.version` greater than this version's schema for
  that file (working copy or build cache): the file is never rewritten. At load
  the workspace is refused (as for a version mismatch, §15 invariant 11), and a
  newer-schema file appearing while a workspace is loaded returns it to that
  refused state instead of being reconciled. The message names both versions
  and the remedy — `.nvim/loomworks.cache.json was written by loomworks X
  (schema N), newer than this loomworks Y (schema M) — update loomworks; the
  file was left unchanged` — and does not offer a reset or a discard as the
  fix, since the file is valid, only newer.
- **Same schema, newer writer** — `written_by` newer than the running version:
  the file is loaded and saved normally, and a warning is shown **once per
  process per file**: `… was written by loomworks X, newer than this loomworks
  Y — update loomworks`. This is safe by rule: a change that adds data an older
  version would drop on rewrite, where the loss matters, **must** bump the
  file's schema version; fields that may be absent without harm (e.g. the
  cache's `artifacts`, §2.3) do not.
- **Older schema** — unchanged: migrated where a migration exists, otherwise
  refused with the reset/discard remedies of §15 invariant 11.

---

