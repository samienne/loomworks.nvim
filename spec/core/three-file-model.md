> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 2. Three-File Model

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
  "_meta": { "version": 2 },
  "name": "reactive",
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "profiles": { ... },
  "intent": { ... },
  "default_target": { ... },
  "device": { ... },
  "lsp": { ... }
}
```

The `device` field maps profile keys to device serial strings:
```json
"device": {
    "Debug:<sdk>-<platform>-<arch>": "FMR0225108000951"
}
```

The optional `name` field overrides the workspace display name (§1.1). It is
present only when the user has set one explicitly (`lw init --name`,
`lw workspace rename`, or the editor); when absent the name defaults to the
root directory basename. Written to `loomworks.json` on publish.

The `intent` field stores explicit per-item intent overrides (see §2.4).

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

The exact glyph is a UI-spec choice (see `spec/ui.md` and `spec/ui-v2.md`).
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

#### Saving (`:w`)

`:w` on the status buffer regenerates loomworks.json from the working copy:

- For every item with effective intent including `shared`, write current
  content to loomworks.json.
- Items previously in the published baseline whose effective intent no
  longer includes `shared` are removed from loomworks.json.
- After write, the published baseline is updated to match the new
  loomworks.json. `+` and removed-upstream indicators clear.

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
  "_meta": { "version": 6, "cached_at": "..." },
  "configurations": {
    "App/Debug:ninja-gcc-12": {
      "project_key": "App",
      "config_key": "Debug:ninja-gcc-12",
      "type": "cmake",
      "state": "built",
      "variant": "Debug",
      "build_dir": "/workspace/.nvim/build/App/Debug",
      "last_configured": "2026-03-10T12:00:00Z",
      "last_built": "2026-03-10T12:05:00Z",
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "cmake": { "generator": "Ninja", "compiler": "GCC 12.3" }
    }
  },
  "profiles": {
    "Debug:ninja-gcc-12": {
      "configuration_set": "Debug",
      "tool_key": "ninja-gcc-12",
      "tool_data": { ... },
      "tool_label": "Ninja + GCC 12.3",
      "tool_mod_type": "cmake",
      "configurations": ["App/Debug:ninja-gcc-12"]
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
- Never auto-removes entries — survives git branch switches intact.
- Grows as builds happen; shrinks only on explicit delete/clean.
- Flat `configurations` dict keyed by opaque `"project_key/config_key"`.
  Each entry is self-describing (includes project_key, config_key, type,
  tool properties). Profiles reference configurations by cache key.
- `deploy_state` dict keyed by normalized absolute destination path. Tracks
  which source config unit's artifact was last deployed to each destination.
  Cleaned when source config units are deleted/cleaned.
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

---

