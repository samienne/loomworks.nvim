# UI

Status page, highlight groups, and the winbar/statusline component.
Section numbers in this file are local. Cross-refs to core sections
use `specification.md §X.Y` form.

---

## 1. Status page

### 1.1 Layout

The status page opens as a floating window (default 100 columns, 90%
editor height). Window position and size can be configured via `setup()`
options or overridden per `open()` call — the `win` table is passed
directly to `Snacks.win`. The page contains these sections in order:

1. **Header** — plugin version, workspace name, workspace root, and one
   `Runtime` line, the header's last line (above Diagnostics, never further
   down the page): the runtime mode, the source that selected it (core
   §19.1: `env`, `setup`, `lw setting`, `default`), and in `daemon` mode the
   observer's current state or note (core §19.16), e.g. `Runtime:   daemon
   (lw setting) — observing daemon pid 4242`, `Runtime:   daemon (setup) —
   no lw host binary (LOOMWORKS_LW: not set; binary.path setting: not set;
   lw on PATH: no lw on the search path; plugin-managed lw: none wanted
   (the plugin carries no pin yet)) — running in-process`, `Runtime:   daemon
   (setup) — downloading the plugin-managed lw v0.1.50 (lw-linux-x86_64) from
   https://… — running in-process meanwhile`, `Runtime:   daemon (env) — the workspace daemon
   disconnected — waiting for it`, `Runtime:   in-process (lw setting)`. A
   note that leaves the editor running in-process although `daemon` was
   selected (a version mismatch, no host binary, a failed download) uses the
   warning highlight.
   Absent only when `in-process` was selected by the default.
2. **Diagnostics** — aggregated structural diagnostics (hidden when empty)
3. **Suggestions** — a single compact line, `N suggestion(s) — run \`lw
   health\``, shown only when the suggestion framework has one or more
   **actionable** items (hidden when none). `N` counts actionable items only
   — informational items (e.g. the affirmative "Compiler cache: using
   `<tool>`") appear in `lw health` but never in the count, so a healthy
   workspace shows no line. Rendered with the `LoomworksStale` highlight
   (hint-level, like the `[stale — reconfigure]` hints: advisory, not a
   warning). It is advisory, not a diagnostic: unlike the
   Diagnostics section, suggestions never gate an operation and never fail
   `--check`. A **missing required** environment-inventory item recorded by a
   prior `lw health` (core §16.33) counts like any actionable item; the page
   never probes the environment itself. The line's detail lives in `lw health` (core §16.31); the
   status page keeps only the count so the page stays uncluttered. The
   first-shipping provider flags a workspace that has C/C++ projects but no
   compiler cache on the toolchain path (see §16.31).
4. **Profiles** — all materialized and explicit profiles
5. **Orphaned Configurations** — unreferenced cached configs (hidden when empty)
6. **Configuration Sets** — declared sets with tool entries
7. **Projects** — all projects with their configurations
8. **Tasks** — active loomworks-managed tasks, tasks observed in the
   workspace daemon, and held build-dir locks (hidden when all empty). Placed at the bottom because it's the
   runtime-state diagnostic surface — only interesting when something
   is wrong.

Sections are separated by blank lines. Each section has a title line.

### 1.2 Tree Structure

The status page uses a foldable tree widget with two-level nesting.

**Node types**:
- `leaf` — plain text line, no interaction. Accepts either `(text, hl)` or
  a list of `{text, hl}` chunks for mixed highlights on one line.
- `node` — foldable line with children, opened with `l` and closed with `h`
- `item` — interactive line with actions, no folding
- `group` — labeled sub-section that increases indentation. Accepts either
  `(label, hl, children_fn)` or `(chunks, children_fn)` for mixed highlights.
- `blank` — empty line for spacing

**Fold characters**: `▶` (folded), `▼` (unfolded)

**Spinner**: Braille animation (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) at 80ms interval,
shown when `spinning = true`. Replaces the status marker for running items.

**Status markers**:
| Status           | Marker |
|------------------|--------|
| unconfigured     | ○      |
| configured       | ◆      |
| built            | ✔      |
| configure_failed | ✘      |
| build_failed     | ✘      |
| running/deleting | (spinner) |

### 1.3 Keybindings

| Key     | Action      | Behavior |
|---------|-------------|----------|
| `<Tab>` | next_item   | Move the cursor to the next interactive line |
| `<S-Tab>` | prev_item | Move the cursor to the previous interactive line |
| `l`     | open_fold   | Open the fold on the current node |
| `h`     | close_fold  | Close the fold on the current node |
| `<CR>`  | enter       | Open action picker on nearest actionable node |
| `b`     | build       | Build (walks up to nearest node with `on_build`) |
| `<C-b>` | build_serial | Build serially (`-j1`), for readable error output (walks up like `b`) |
| `c`     | configure   | Configure (walks up to nearest node with `on_configure`) |
| `o`     | options     | Show build options float (on configured project nodes) |
| `t`     | task        | Open overseer task output for nearest config (float) |
| `R`     | rebuild     | Clean + build (destructive, with confirmation) |
| `C`     | clean       | Run module clean tasks, reset to configured (with confirmation) |
| `D`     | delete      | Delete profile or configuration (destructive, with confirmation) |
| `N`     | init_workspace | Initialize workspace: create user.json in cwd |
| `L`     | load        | Load workspace from cwd / rescan tools |
| `<C-n>` | nuke        | Reset workspace: delete `.nvim/build/` + cache, reload (destructive, with confirmation) |
| `P`     | publish     | Cycle intent (`local` → `local+shared` → `shared`) on nearest publishable item |
| `e`     | describe    | Edit the description (core §1.10) of the nearest describable item — profile, configuration set, project, or user configuration — in the description editor (§1.16) |
| `K`     | hover       | Hover popup with the full content of the current line; a row may supply its own hover content (on a describable item, its full description, §1.16) |
| `U`     | delete_user | Delete user.json and reload (with confirmation); for a refused working copy (core §17.4) this is the discard action |
| `T`     | trust       | Refused working copy (core §17.4): review its summary and trust (re-sign) it |
| `:w`    | (write)     | Publish: regenerate loomworks.json from working copy |
| `:e`    | (edit)      | Reload from published baseline (refused if any divergence) |
| `:e!`   | (force edit)| Force-revert workspace to baseline (preserves data, drops publication wishes for unmatched items) |
| `?`     | help        | Show help dialog |
| `q`     | (close)     | Close the status page |

**Action dispatch**: For `build`, `build_serial`, `configure`, `rebuild`, `clean`,
`delete`, `options`, and `describe`, the tree walks upward from the cursor line to find the
nearest node that has the corresponding `on_<action>` callback. This means pressing
`b` on a child detail line triggers the build action of the parent node.

**Action picker (`<CR>`)**: The Enter key walks up to the nearest widget with
`on_*` callbacks, collects all available actions, and opens `vim.ui.select`
with the action list. The `enter` action label is context-dependent, set by
the section renderer via the `enter_label` field on the widget:
- Profile nodes: "Activate"
(`describe` also appears in every describable node's action list as
"Edit description", so it is discoverable without knowing `e`.)
- Config set tool entries: "Activate"
- Project config/tool nodes: "Open task output"

The picker is skipped (direct invoke) when:
- The widget has `direct = true` (sentinel lines), OR
- Only one action exists on the widget (no other actions to discover)

**Sentinel lines**: Interactive `item` nodes that appear at the end of
sections to provide discoverable create/add flows. Sentinels have
`direct = true` on the widget, so Enter invokes `on_enter` immediately.
- **Profiles section**: `▸ Create new profile` — opens the profile creation
  multi-step picker (config set → tool → materialize). Shows "No projects
  yet." when no projects exist.
- **Projects section**: `▸ Add project` — opens the project browser float.

**Destructive action highlighting**: `R`, `C`, `D`, `U`, `<C-n>` keys are
highlighted with `DiagnosticWarn` in the help dialog.

### 1.4 Action Hints

Action hints show available keys close to the actionable items. Hints use
`Comment` highlight. Format: `[key] label  [key] label  ...` — keys in
brackets, separated by double spaces.

**Header hint**: After the Root line, a `Comment` leaf shows global actions:
`[?] help  [L] load  [<C-n>] reset`

**Refused-state hint**: When the workspace failed to load because a `.nvim`
file was refused (core §17.4), the page shows only the load error (title,
`Failed to load workspace`, root, message) followed by a blank line and a
`Comment` hint naming the remedy for the refused file:
- refused working copy (`user.json`): `[T] review & trust  [U] discard working copy`
- refused build cache: `[<C-n>] reset build cache`

**Group header hints with `[t]`**: Profile project groups also include `[t] task output`.

**Section title hints**: Some sections show a `Comment` hint line after the
title listing available actions for top-level nodes.

| Section | Hint line |
|---------|-----------|
| Profiles | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Orphaned Configurations | `[D] delete` (appended to title via chunks) |

**Group header hints**: Inner groups that contain actionable items append a
hint suffix to the group label. The label uses `LoomworksActionable` highlight
and the suffix uses `Comment` highlight (via `group` with chunks).

| Group label | Section | Hint suffix |
|-------------|---------|-------------|
| Projects: | Profiles | `[b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Tools: | Configuration Sets | `[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete` |
| Configurations: | Projects | `[b] build  [c] configure  [o] options  [R] rebuild  [C] clean  [D] delete` |

### 1.5 Profiles Section

Shows all materialized (cached) and explicit profiles. Profiles only appear
here when they exist in the cache or are declared in the config.

**Profile node display** (all profiles use the same rendering):
```
{marker} {fold_char} {profile_key} [{tag}] ({status_label}) [{elapsed}] [— {op_message}]  {summary}
```

Where:
- `{tag}` = `[stale]` for orphaned profiles, `[explicit]` for declared
  profiles, omitted otherwise. A profile that shares an output artifact with
  another profile (its resolved artifact set overlaps — see `specification.md`
  §5.9) additionally carries a `[conflict]` tag, highlighted
  `LoomworksConflict`. The tag is absent while a profile is unconfigured, since
  artifacts are unknown until configure (`specification.md` §5.9).
- `{status_label}` = aggregate status from `Profile:status()` (e.g., "built",
  "1 configuring, 1 failed build", "3 configured, 2 unconfigured")
- `{elapsed}` = shown only when running (e.g., "1m23s")
- `{op_message}` = last operation result (e.g., "built in 42s")
- `{summary}` = the profile's description summary (§1.16), fitted to the
  remaining width; omitted when the profile has none

All profiles are displayed identically. A profile with key `"Debug:ninja-gcc"`
appears like any other profile; it simply has fewer projects when expanded.

**Profile highlight rules**:
| Condition | Highlight |
|-----------|-----------|
| Has active Operation + active | `LoomworksActive` |
| Has active Operation + not active | `LoomworksRunning` |
| Active (no operation) | `LoomworksActive` |
| Failed status | `LoomworksFailed` |
| Unconfigured | `LoomworksUnconfigured` |
| Otherwise | `LoomworksConfigured` |

Note: "Has active Operation" means this profile initiated the action.
Profiles that share ConfigUnits with the initiating profile show spinners
(from running ConfigUnit state) but not the orange highlight or timer.
A remote task observed in the workspace daemon (core §19.16) counts as the
active Operation of the profile its `start` meta names, with the same
highlight, spinners and timer, plus its origin marker (§1.9) after the
timer. The Cancel action below does not cover it (the editor cannot cancel a
remote task); a profile whose only running tasks are remote offers no Cancel.

**Cancel action** (added to the Enter picker when `profile:is_running()`):

The action picker on a running profile includes `Cancel running task(s)`.
On select, every unit mapped by the profile's config_set with an active
task_id has its task stopped via `Workspace:cancel_tasks_for_profile`.
Tasks chained behind a cancelled one (e.g. the build link after a
configure) auto-abort because the Future token in `start_one_task` bails
their `do_start` before the next launch. A notification reports the
count cancelled. The same picker entry appears on per-configuration
rows for fine-grained single-task cancel. Cancel is not exposed as a
direct hotkey — only through the picker — because the destructive
scope (profile-level) benefits from the explicit pick.

**Profile children** (when unfolded):
- Description (only when the profile has one) — the full description,
  rendered per §1.16, as the first child
- Set name (with warning if orphaned/stale) — only for set-based profiles
- Toolchain — a single profile-level row. A toolchain is one decision
  (host tools or an SDK kit identity `(sdk, platform, arch)`) shared
  across every tool-needing module in the profile. Row format
  `Toolchain: <label>`. Label resolution: for SDK kits the canonical
  shape is `<platform> <version> <arch>` (e.g. `Android 14
  arm64-v8a`); for host selections it's `<tool_label> [host/<mod_id>]`
  per module; otherwise `(none — incomplete)`. `<CR>` opens the
  unified picker — entries are host tools from each tool-needing
  module's registry plus one entry per kit from each resolved SDK
  (sourced from `SDK:kits()`), with a `(none)` sentinel.
  Picking an SDK kit calls each tool-needing module's `kits_from_sdk`
  with the chosen `(sdk, platform, arch)`, matches by the kit's
  composite `id`/`kit_id`, and stores the per-module tool_data
  atomically. Host picks set only the target module's `_tools_raw`
  entry and clear the SDK.
- Compiler cache — a single profile-level row, sibling to the Toolchain
  row, shown for a profile that contains a C/C++-caching module. Format
  `Cache: <tool>` naming the resolved launcher (`ccache` / `sccache`), or
  `Cache: off` when the effective `cache` policy (core §1.3.2) is `off`, or
  `Cache: auto (none found)` when policy is `auto` but no
  launcher is present on the toolchain path, or `Cache: <policy> (not found)`
  (e.g. `Cache: ccache (not found)`) when the policy names a launcher
  explicitly but it is not present — the build then runs uncached, and
  `lw health` reports it as an actionable item — or `Cache: auto (off for MSVC-style)`
  when policy is `auto` on an MSVC-style compiler, which never enables a
  launcher automatically (core §1.3.2) — the headless row adds a pointer to
  `lw help cache`, which explains how to opt in — or `Cache: not applied (<reason>)` when the policy is not `off` but
  the module cannot apply a launcher to the profile's configuration at all
  (core §8 `cache_launcher_applicable`, with the module's reason, e.g.
  `not applied (preset)` or `not applied (Visual Studio 17 2022 generator)`);
  the row then never names a launcher the build does not use. The row is informational only in v1 (no picker); the policy is
  edited through the variable
  system. When the launcher currently resolved differs from the one the
  profile's configured units were built with (§8.1 `compiler_cache`
  staleness, core §5.1), the row carries a `[stale — reconfigure]` hint
  (highlight `LoomworksStale`) meaning the next build reconfigures to apply
  the change. The per-configuration cache mismatch also surfaces as the same
  `[stale — reconfigure]` hint on the affected project row under the profile
  (alongside the `(status)` suffix), so the user sees which configs will
  reconfigure.
- Default target, shown as `Target: <project>:<name>`, or `(stale)`, or
  `(no target set)`. `<CR>` opens the Build / Switch target picker. For a
  launch configuration, the row appends its description summary (§1.16).
- Device selection (only when the profile contains a project from a
  device-capable module) — shows `Device: <name> (<serial>)` (online),
  `Device: <serial> (offline)` (offline/stale), or
  `Device: (none selected)`. `<CR>` opens device picker.
- (The last-operation message is shown in the profile header line via
  the `— <message>` suffix, not repeated here.)
- Projects sub-group:
  - Each project: `project_key [module_type] → variant (status) {progress} {overwritten_tag}`
    with status highlight. The `(status)` suffix mirrors the profile
    header's `(status)` so the expansion doesn't need a separate
    `Status:` leaf. `{overwritten_tag}` = `[overwritten]` (highlight
    `LoomworksConflict`) when this config unit was built but another unit's
    build has since overwritten its shared output artifact (`specification.md`
    §5.9) — the built marker (✔) is retained, the tag signals the on-disk
    artifact is no longer this unit's. Same category as the `!` refresh tag
    (§1.8): the unit needs a rebuild to reclaim its output.
  - When unfolded: build dir and targets only. Tool / generator /
    compiler leaves are dropped — the toolchain is shown once per
    profile in the profile-level Toolchain row, not repeated per
    config.

**Profile actions**:

| Node type | `<CR>` | `b` | `c` | `t` | `R` | `C` | `D` |
|-----------|--------|-----|-----|-----|-----|-----|-----|
| Profile | activate | build all | configure all | — | clean+build all | clean all | delete with dialog |
| Project under profile | open task output | build config | configure config | open task output | clean+build config | clean config | delete config with dialog |

**Sentinel: Create new profile**

After the profile list (or as sole content when empty), an interactive item:
```
▸ Create new profile
```
Enter opens the profile creation multi-step picker:

1. **Pick configuration set**: Shows existing config sets from the
   workspace config, plus auto-detected options from
   `generate_default_config_sets()`. Auto-detected options are labeled
   `"Name (auto-detected)"` with a mapping summary. Selecting an
   auto-detected option writes it to user.json via
   `add_configuration_set()` before continuing.

2. **Pick tool** (skipped if module has no keyed tools, or only one tool
   detected): Shows available tools from `detect_tools()`.

3. **Materialize**: Calls `config_set:ensure_profile(tool_entry)` to
   create the profile in cache. Auto-activates only when this is the
   first profile in the workspace; otherwise just creates it.

When no projects exist, the sentinel is replaced with:
```
No projects yet. Add projects first.
```

### 1.6 Orphaned Items Section

Shows orphaned cached configurations and stray build directories. Visible
when either type exists (hidden otherwise — the common case).

**Title**: `Orphaned Items` with `Title` highlight.

**Orphaned configurations**: cached configs with build state not referenced
by any profile. Grouped by project key (sorted alphabetically). Each
project is a foldable node; each config within is a foldable node showing
the config key and its status.

**Stray build directories**: directories under `{root}/.nvim/build/` not
referenced by any cache entry. Detected via top-down pruning: the scan
reports the highest-level directory whose entire subtree contains no cache
entries. Directories that ARE cache entries (or parents of cache entries)
are skipped. Shown as flat items with `(stray)` suffix.

```
Orphaned Items  [D] delete

  ▶ App
    ▶ Debug:ninja-gcc-12 (built)
      Status: built
      Build dir: .nvim/build/App/Debug
  .nvim/build/OldProject (stray)
  ▸ Clean all
```

**Highlight**: Project nodes use `LoomworksUnconfigured`. Config nodes use
`resolve_config_status()` highlights. Stray dir items use
`LoomworksUnconfigured`.

**Actions**: `D` (delete) is mapped on config nodes and stray dir items.
All other action keys (`b`, `c`, `R`, `C`, `p`) are not bound — orphaned
items cannot be built or configured. Deletion shows the standard
confirmation dialog.

**Sentinel: Clean all**

After the last orphaned item:
```
▸ Clean all
```
Enter shows a confirmation dialog listing:
- All orphaned cached configurations (with state and build dirs)
- All stray build directories

On confirm: deletes orphaned cache entries + build dirs via `_run_deletion`,
then deletes stray build dirs. If nothing to clean, shows a notification.

### 1.7 Configuration Sets Section

Shows configuration sets from the merged config (loomworks.json + user.json).
Only appears when sets exist.

**Set node display**:
```
{fold_char} {modified_tag}{set_name}  {summary}
```

Where `{modified_tag}` = "+" if the set is modified (see `specification.md` §2.4),
empty otherwise, and `{summary}` is the set's description summary (§1.16). Shared-only sets (not in user.json) are dimmed (`Comment`).

Highlighted with `LoomworksActive` if the active profile belongs to this set,
otherwise `LoomworksActionable` (or `Comment` if shared-only).

**Set node actions**:

| Action | Behavior |
|--------|----------|
| `<CR>` | Action picker: Edit mappings, Edit description, Create profile from set, Delete |
| `e`    | Edit description (§1.16) |
| `D`    | Delete config set with confirmation dialog |

**Config set editing** (`<CR>` on a set node):

Opens a dedicated config set editor dialog. Shows each project in the
workspace with its current variant mapping and available configurations
(from module.info). The user can change each mapping via `vim.ui.select`
or set it to "None" to remove the mapping. Accept (`y`) applies changes
via `update_config_set_mapping()` for each changed mapping. Cancel (`q`)
discards changes.

Changed mappings may orphan existing cached configs (old variant no longer
referenced). This is intentional — orphans are cleaned explicitly via the
"Clean all orphaned items" action in the Orphaned Configurations section.

**Config set deletion** (`D` on a set node):

Shows a confirmation dialog listing:
- Profiles that reference this set (will become orphaned-set)
- Warning that cached configs will become orphaned

On confirm: `remove_configuration_set()`. Profiles that referenced the set
become orphaned_set. Cached configs for those profiles become orphaned. No
immediate deletion of cache entries — the user cleans via "Clean all orphaned
configs" in the Projects section.

**Set children** (when unfolded):
- Description (only when the set has one), rendered per §1.16
- Projects sub-group: `project_key → variant`
- Tools sub-group (if keyed tools detected): one item per detected tool

**Tool entry display**:
```
{marker} {tool_label} {suffix}
```

Where:
- `{marker}` = status marker for the corresponding profile (if materialized)
- `{suffix}` = status/progress info if materialized, empty if not
- Highlight follows same rules as full profiles

**Tool entry actions**:

| Action | Materialized profile exists | No materialized profile |
|--------|---------------------------|------------------------|
| `<CR>` | activate | activate (materializes first) |
| `b`    | build via profile | build via `run_profile_action` (materializes first) |
| `c`    | configure via profile | configure via `run_profile_action` (materializes first) |
| `R`    | rebuild via profile | nil (no-op) |
| `C`    | clean via profile | nil (no-op) |
| `D`    | delete profile with dialog | nil (no-op) |

**Sentinel: Create configuration set**

After the last config set, an interactive item:
```
▸ Create configuration set
```
Enter opens a picker with two kinds of options:

1. **Auto-detected templates** — generated by `generate_default_config_sets()`
   using `map_variant()` on all projects. Standard templates: "Debug" and
   "Release". Each template pre-fills project→configuration mappings by
   matching variant types across modules. Templates that match an existing
   config set name are excluded.
2. **Custom** — opens the config set editor dialog with empty mappings.
   User enters a name and manually selects variant per project.

Selecting a template creates the config set immediately with the
pre-computed mappings. No editor dialog — the mappings are deterministic.

This replaces the previous flow where all config sets started from the
editor dialog.

### 1.8 Projects Section

Shows all projects from the active set, including orphaned projects. Projects
are sorted alphabetically with orphaned projects at the end.

**Project node display**:
```
{fold_char} {modified_tag}{project_key} [{type}] {orphan_tag} {refresh_tag}  {summary}
```

Where:
- `{modified_tag}` = "+" if any child or the project declaration is modified
  (see `specification.md` §2.4), empty otherwise
- `{orphan_tag}` = "(orphaned)" if in cache but not in config
- `{refresh_tag}` = "!" if `needs_refresh` is true
- `{summary}` = the project's description summary (§1.16)
- Under a project's configuration/tool rows, a config unit whose built output
  was overwritten by a conflicting unit (`specification.md` §5.9) carries an
  `[overwritten]` tag (highlight `LoomworksConflict`), matching the profile-side
  rendering (§1.5).

**Shared-only items** (exist only in loomworks.json, not in user.json) are
displayed with `Comment` highlight (dimmed). Module-generated default
configurations are also dimmed. Dimmed items become normal on first
interaction (auto-copied to user.json).

**Project children** (when unfolded):
- Description (only when the project has one), rendered per §1.16
- Path
- Refresh reasons (if any, with `!` prefix and `DiagnosticWarn` highlight)
- Configurations sub-group

**Configuration display** (keyed-tool modules):
Each configuration shows its available tools:
```
{fold_char} {config_name} {brief}  {summary}
  Description …                           ← only when it has one (§1.16)
  {fold_char} {tool_label} {progress}     ← one per detected/cached tool
    Status: {status}
    Build dir: ...
    Last configured: ...
    Generator: ...
    {fold_char} Targets ({total_count})       ← only when targets exist
      {fold_char} {type_group} ({group_count})
        {fold_char} {target_name}
          Links: dep1, dep2
```

**Configuration display** (non-keyed modules):
```
{fold_char} {config_name} {brief}  {summary}
  Description …
  {fold_char} Status: {status} {progress}
    Build dir: ...
    ...
```

**Targets sub-tree** (post-configure only, modules with `parse_targets`):

When a configuration has cached targets, a foldable "Targets (N)" node
appears in the unfolded tool entry detail view, where N is the total
target count. Targets are grouped by type under foldable sub-headers
showing the group name and count (e.g., "Executables (2)"). Within each
group, targets are sorted alphabetically by name. Targets with link
dependencies can be unfolded to show `Links: dep1, dep2, ...` on a
single line. Targets without dependencies are leaf nodes (no fold arrow).

Type group labels and display order:
1. `Executables`
2. `Static Libraries`
3. `Shared Libraries`
4. `Module Libraries`
5. `Object Libraries`
6. `Interface Libraries`

Only groups containing at least one target are shown.

**Configuration actions** (at the tool/status level):

| Action | Behavior |
|--------|----------|
| `D`    | Delete config with dialog |

**Tool entry highlight rules** (keyed-tool modules):

| Condition                       | Highlight              |
|---------------------------------|------------------------|
| Running                         | `LoomworksRunning`     |
| Deleting                        | `LoomworksDeleting`    |
| Active (matches active profile) | `LoomworksActive`      |
| Failed                          | `LoomworksFailed`      |
| Configured/Built (not active)   | `LoomworksConfigured`  |
| Unconfigured                    | `LoomworksUnconfigured`|

A tool entry is "active" when the active profile's tool_key matches the
entry's tool_key and the configuration variant matches the project's active
configuration.

**Non-keyed module highlight rules** follow the same pattern but without
tool_key matching — the entry is active when its variant matches the
project's active configuration.

**Launch configurations sub-group**

After the configurations group, each non-orphaned project shows a
"Launch:" group listing its launch configurations.

Each launch config item shows `{name}  {summary}  {runs}`:
- `{summary}` is the launch's description summary (§1.16). The launch items of
  a project form a summary column, at most 36 display columns and blank for
  launches without a description. This is the same layout rule as the CLI
  (core §16.35).
- `{runs}` is the open-ended tail: `target:<t>` or the command, then the args.
  It is dimmed and cut with `…` to the window width.

Actions:

| Action | Behavior |
|--------|----------|
| `<CR>` | Edit launch config (opens launch editor dialog) |
| `e`    | Edit description (§1.16) |
| `K`    | Full description, or the full command line when there is none |
| `D`    | Delete launch config with confirmation |

A "Add launch config" sentinel opens the launch editor for a new config.

The **launch editor dialog** edits: name, command, args (space-separated),
working directory, and environment variables (key=value pairs). Env vars
can be added (`▸ Add variable`) and removed (`D`). Inline name validation
prevents duplicates and invalid launch names (core §8.7). Accepts with `y`,
cancels with `q`.
- **Fields it does not show are kept.** Saving never drops `target`, `device`,
  `device_log`, `description` or any field it does not edit.
- **Description.** For an existing launch it shows a `Description ▸ <summary>`
  row that opens the description editor (§1.16). The description editor saves
  independently of the dialog's accept.
- **Rename.** Changing the name and accepting is a **rename** (core §8.7): the
  same atomic operation as `lw launch rename`. Every field moves, and every
  profile's default target that named the launch follows. It is never a delete
  plus re-create.

**Sentinel: Add project**

After the last project (or as sole content when no projects exist), an
interactive item:
```
▸ Add project
```
Enter opens the project browser float (§1.14). Replaces the former `A`
keybinding.


### 1.9 Tasks Section

Diagnostic and recovery surface for active task lifecycle state.
Renders nothing when no tasks are running and no build-dir locks are
held — quiet during idle. Placed at the bottom of the status page
because it's only interesting when something is wrong; the day-to-day
reader sees workspace state first.

**Section content** (in render order):

1. Title line `Tasks  [N active]` where N is the active-task count.
2. Top action row `⟲ Reset all task & lock state` (warn highlight)
   — Enter opens a confirmation dialog; on confirm, cancels every
   active task and force-releases every held lock. Nuclear option for
   the case where bookkeeping has wedged.
3. One row per active task:
   ```
   ▸ {project_key} : {config_key} — {action}  [N/M]  {elapsed}
   ```
   - `{action}` is `configure` / `build` / `clean`.
   - `[N/M]` is the most recent progress update (omitted when none).
   - `{elapsed}` is the time since the task was registered (`30s`,
     `1m4s`). The spinner marker animates while the task is live.
   - **Enter** opens a `vim.ui.select` menu: `Cancel task` (calls
     `task:stop()` via `Workspace:cancel_task`) and `Open overseer`
     (opens the overseer task list for output inspection). Esc
     dismisses without action.
4. **Remote tasks** observed in the workspace daemon (core §19.16) — an
   operation started elsewhere, e.g. `lw build` in a terminal — are rows of
   item 3, in the same format, ordered with the local ones by start, with
   an origin marker as the row's last token:
   ```
   ▸ {project_key} : {config_key} — {action}  {pct}%  {elapsed}  {origin}
   ```
   - `{action}` is the task's `kind`; `{pct}%` is its last progress tick
     (omitted before the first), in place of `[N/M]`.
   - `{origin}` is `lw` (started by the CLI) or `editor` (another editor),
     dimmed; local tasks have none.
   - One row per unit of the task's profile (resolved units by their domain
     objects, unresolved ones by the names the daemon sent); a task with no
     units shows one row `▸ {profile} — {action}  {origin}`.
   - **Enter** offers `Show output` (the same output view as a local task's,
     following the stream while the task runs; capped, core §19.16); no
     `Open overseer` (a remote task is not in the task runner's list) and no
     `Cancel task`: the task belongs to its client (core §19.15). The reset action above leaves remote tasks alone.
5. Sub-section `Build directory locks` (only when at least one lock
   is held or has a non-empty queue):
   ```
   ▸ {build_dir}  exclusive · shared(N) · queued(N)
   ```
   - Tokens appear only when their count is non-zero; entries with
     all zeros are elided by `get_build_dir_locks_info`.
   - A queue with no live holder (shared_count=0, exclusive=false,
     queue_depth>0) is highlighted with `DiagnosticWarn` — the
     visual cue for the "stuck PENDING" scenario.
   - **Enter** opens a `vim.ui.select` menu with one option
     `Force-release lock` (zero the counts, replay the FIFO queue).
     Idempotent with respect to the real holder's eventual release.
     Esc dismisses.

**Section invariants:**

- Renders nothing when `get_active_tasks()`, `get_daemon_tasks()` and
  `get_build_dir_locks_info()` are all empty.
- A remote task's unit reports the same running state as a local task's
  everywhere a unit's state is shown (Profiles, Projects, build directories,
  the statusline component), the statusline spinner runs while any remote
  task runs, and both clear when it ends (core §19.16, End).
- Per-row Enter opens a menu rather than firing directly. Both
  actions are recoverable, but a misclicked cancel costs a full
  rebuild on a large project — the menu serves as a one-keystroke
  confirmation.
- Top-level reset uses the heavier confirmation dialog because it
  acts on multiple items at once.


### 1.10 Deletion Confirmation Dialog

Shown for all delete operations (`D` key). Floating window centered in editor.

**Content**:
1. Title (e.g., "Delete profile: Debug:ninja-gcc-12")
2. Running tasks that will be stopped (if any)
3. Items that will be removed (`disposition = clean`)
4. Items that will be reset (`disposition = reset`)
5. Items that will be kept (`disposition = keep`, referenced by another
   profile)
6. Confirmation prompt

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

### 1.11 Nuke Confirmation Dialog

Shown when `<C-n>` is pressed. Floating window centered in editor.

**Content**:
1. Title: "Reset workspace cache"
2. List of paths that will be deleted:
   - `<root>/.nvim/build/`
   - `<root>/.nvim/loomworks.cache.json`
3. Confirmation prompt

**Root resolution**: Uses `ws.root` if a workspace is loaded, otherwise
resolves from cwd via `workspace.resolve_root()`.

**Refused before it is shown**: the nuke's safety checks and locks are
checked first (`nuke_check(root)`, spec §19.3 — another process's build or
workspace operation); a refusal shows only an error notification
(`loomworks: cannot nuke: …`) and no dialog.

**Keys**: `y` = confirm and execute, `q`/`<Esc>`/`n` = cancel

**Safety checks** (in `nuke_cache(root)`):
1. Root must be an absolute path (rejects relative paths)
2. `loomworks.json` must exist at the root (confirms it is a real workspace)
3. Every path to delete is verified to be under `root/.nvim/` using
   normalized path prefix checking (prevents directory traversal)

If any check fails, the operation aborts with an error notification and
no files are deleted. These checks are specific to the nuke operation —
the general io layer does not restrict deletion paths, because normal
config/profile deletion may delete build directories anywhere.

### 1.12 Help Dialog

Floating window showing all keybindings. Destructive keys (`R`, `C`, `D`,
`<C-n>`) have their key character highlighted with `DiagnosticWarn`.

### 1.13 Options Float

Triggered by `o` on a configuration or tool entry node in the Projects
or Profiles section. Opens a floating window showing the project's build
options for that configuration. Only available for configured projects
with a cached build directory.

**`Core:get_project_options(project_key, config_key) → (OptionGroup|Option)[]|nil`**

Resolves the build directory from cache and delegates to the module's
`get_options()`. Returns nil if the project is not configured or the
module does not support options.

The float uses a Tree widget with foldable groups. The module returns a
tree of `OptionGroup` and `Option` nodes. Each group shows its label and
child count. Each option shows `key = value`. BOOL values are highlighted
(ON = green, OFF = dimmed). Options with helpstrings show them as
children when unfolded. Options with choices show them in parentheses
after the value. Fold/unfold with `<Tab>`.

The float is read-only. Close with `q` or `<Esc>`.

### 1.14 Project Browser

The project browser is a float opened from the "Add project" sentinel line.
It scans workspace subdirectories asynchronously and shows detected project
types using each module's `detect()` method.

**Layout**: Tree widget in a `Snacks.win` float. Title: "Add Project".

**Entry display**: Each directory entry shows its name followed by detected
type tags (e.g., `MyProj  [<module>: <marker>]`). Directories matching
multiple modules show all tags. Already-added projects show `✓` with
`DiagnosticOk`. Directories with no detection show `Comment` highlight.

**Async scanning**: On open, `modules.scan_directory_async()` scans the
workspace root. On fold open, subdirectories are scanned lazily. Results
are cached in a browser-local dict. Pending scans show "scanning...".

**Filtered directories**: `.git`, `.nvim`, `.cache`, `.vs`, `.vscode`,
`node_modules`, `build`, `out`, `__pycache__`, and all hidden directories
(starting with `.`) are excluded from scanning.

**Keybindings**:

| Key     | Action  | Behavior |
|---------|---------|----------|
| `<CR>`  | enter   | Picker with Add/Remove by module type (see below) |
| `d`     | remove  | Remove project from workspace (with confirmation) |
| `r`     | refresh | Clear scan cache and re-scan |
| `q`     | close   | Close the browser |

**Project key derivation**:
- Root-level directories: basename as key, `path` field omitted
- Nested directories: relative path (with `/` → `_`) as key, explicit `path`
  field

**Enter picker**: Each browser entry has a context-dependent picker:
- Unadded types show `Add [type]`
- Already-added types show `Remove [type]`
- Single add action: always shows picker (user confirms)
- Mixed state: both add and remove options appear

**Configuration mapping dialog**: When adding a project to a workspace
that already has configuration sets, a mapping dialog opens instead of
adding immediately.

The dialog layout depends on the module type and workspace state:

**Keyed module, no tool selected** — tool row first, no mappings:

```
  Add "<project>" [<module>]

  Tool:  None ▸

  Project will be added without configuration mappings.

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool selected** — tool row first, then mappings:

```
  Add "<project>" [<module>]

  Tool:  <tool label> ▸

  Debug     Debug ▸
  Release   Release ▸

  Profiles to upgrade:
    Debug → Debug:<tool_key>

  [Enter] change  [y] accept  [q] cancel
```

**Keyed module, tool inherited** — when existing profiles already have
a tool, the tool is inherited automatically. No tool row; mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     Debug ▸
  Release   Release ▸

  [Enter] change  [y] accept  [q] cancel
```

**Non-keyed module** — mappings only:

```
  Add "<project>" [<module>] — Map configurations

  Debug     <variant> ▸
  Release   <variant> ▸

  [Enter] change  [y] accept  [q] cancel
```

The profile upgrade preview shows only profiles whose config set has
a non-None mapping for the new project.

- Enter on a mapping row opens `vim.ui.select` with configurations + "None"
- Enter on the tool row opens `vim.ui.select` with detected tools
- `y` accepts: chains decomposed operations (see below)
- `q`/Esc cancels: project is NOT added
- Skipped when no config sets exist or project has no detectable configs
- No success notifications — UI state changes are sufficient. Only
  errors are shown via `vim.notify`.

**Tool detection gating**: When the module has keyed tools, the project
browser ensures tool detection has completed before opening the mapping
dialog. If detection is still running, the dialog opens in the callback
after detection completes.

**Decomposed add-project operations**: On accept, the mapping dialog
chains three atomic operations. Each operation saves to disk and
remerges independently. Each intermediate state is valid — if the
process crashes between steps, no data is lost or corrupted.

1. `ws:add_project(key, type, path)` — adds the project entry to
   user.json. Project shows as unmapped.
2. For each config set with a non-nil mapping:
   `ws:update_config_set_mapping(set, key, variant)` — adds one
   mapping to one config set.
3. If a tool was selected or inherited:
   `ws:upgrade_profiles_for_tool(tool_entry)` — upgrades cached
   no-tool profiles to keyed profiles (renames, adds tool fields,
   creates skeleton cache entries). Extends existing keyed profiles
   with skeleton entries for the new project.

**Cache cleanup on removal**: The removal confirmation dialog shows all
cached configurations for the project that will be deleted. Entries with
build state (configured/built/failed) are listed with their build
directories. Skeleton entries (unconfigured) are silently included.

**Profile downgrade on removal**: When removing a project whose module
has keyed tools, the project browser checks whether it is the last
project of that module type. If so, the removal confirmation dialog also
shows a profile rename preview.

After confirmation:
1. `ws:remove_project(key)` removes the project from config and config sets.
2. Cached configurations for the project are deleted (entries removed from
   cache, build directories deleted asynchronously via safe deletion).
3. `ws:downgrade_profiles_from_tool(mod_type)` strips tool suffixes from
   affected profiles when the last keyed-module project is removed.

This is not "auto-clean" — it is an explicit user action with a
confirmation dialog showing exactly what will be deleted.

**File mutation**: All changes write to `loomworks.user.json` via Workspace
mutation methods. Each method saves and remerges independently. Published
items are written to `loomworks.json` only on explicit `:w` (see
`specification.md` §2.4).

Available Workspace mutation methods:
- `add_project(key, type, path?)` — add a project entry
- `remove_project(key)` — remove project + clean up config sets
- `update_config_set_mapping(set_name, project_key, variant)` — update
  one mapping in a config set
- `add_configuration_set(name, mappings)` — add a config set
- `remove_configuration_set(name)` — remove a config set
- `upgrade_profiles_for_tool(tool_entry)` — upgrade no-tool profiles
  to keyed profiles; extend keyed profiles with new project entries
- `downgrade_profiles_from_tool(mod_type)` — strip tool from profiles
  when last project of a keyed-module type is removed
- `compute_downgrade_preview(project_key)` — compute profile renames
  that would occur if a project were removed (pure query, no mutation)

### 1.15 Auto-refresh

The status page refreshes automatically on these events:
- `task_started`, `task_stopped`, `task_result`, `task_progress`
- `deletion_started`, `deletion_completed`, `deletion_failed`
- `active_set_changed`
- `operation_started`, `operation_finished`

Refreshes are coalesced via `vim.schedule` to avoid redundant redraws.

An animation timer (80ms) runs when any node has `spinning = true`, providing
smooth spinner animation for running/deleting states. The timer stops
automatically when no spinners are active.

---

### 1.16 Descriptions

Projects, user configurations, configuration sets and profiles may carry a
description (`specification.md` §1.10). The first line is the **summary** and
the rest is the **body**. All description text is display-only and rendered
inert (`specification.md` §17.11). Control characters are shown visibly, a
buffer line never receives an embedded newline, and highlighting comes only
from `LoomworksDescription` ranges the renderer applies, never from the text.

**Summary on a node line.** The summary is appended after the node's existing
text, separated by two spaces and highlighted `LoomworksDescription`. It is
**fitted to the available width**:

- The width is the status window's text width, minus the node line's display
  width, minus the two-space gap and one column of margin, and **at most 60
  display columns**.
- The summary is cut in display columns (`strdisplaywidth`, never bytes) and ends
  in `…` when cut. When fewer than 12 columns remain, it is omitted from the node
  line; the expanded node and `K` still show it.
- The fit is recomputed on every render. The page re-renders on window resize.

Nodes that carry a summary: profile nodes (§1.5), configuration-set nodes
(§1.7), project nodes (§1.8), configuration rows (§1.8) and launch config
items (§1.8, as a column before the command line). Launch targets also show
their summary:
- on a profile's `Target:` row (§1.5);
- in the target picker and the launch picker (`name (launch)  summary`);
- in the launch editor's `Description ▸` row. A generated
configuration with a module-provided default description (core §1.10) shows
it the same way.

**Expanded node.** The first child of an unfolded describable node is its
description:

- one `LoomworksDescription` leaf per description line, with the blank line
  between summary and body kept;
- each leaf cut to the window width with `…`;
- at most **8 lines**, followed by a `… N more lines — [K] full description` leaf
  when longer.

A module-provided default is labelled `(from project files)` on its first leaf.

**Hover (`K`).** On a describable node or any of its description leaves, `K`
opens the existing hover popup with the **full** description. The popup is
wrapped at its width, with no line or length cap. For a generated
configuration, the popup notes that the text comes from the project files and
cannot be edited here.

**Pickers and dialogs.** Wherever a picker or dialog lists describable items,
each entry shows `name  summary`, with the summary fitted to 40 display columns
and passed as a plain string with no highlight markup. This covers:

- the profile picker (`● key (status)  summary`);
- create-profile step 1, the configuration-set choice;
- the deletion confirmation dialog (§1.10), where the summary follows the
  title line so the user can confirm which item is going;
- the configuration-set editor and configuration editor dialogs. Each gains a
  `Description ▸ <summary>` row, and `<CR>` on that row opens the description
  editor. The editor saves the description itself, independently of
  the dialog's accept or cancel. The row is shown only for an existing set or
  user configuration.

Notifications name items by key only and never include description text.

The description editor's item kinds include **launch configuration**. Its title
is `Description — launch configuration <project>:<name>`.

**Description editor (`e`).** `e` on a describable node, or "Edit description"
from its `<CR>` picker or from an editor dialog's `Description ▸` row, opens a
floating scratch buffer in the style of a git commit message. The buffer
settings are `buftype=acwrite`, `bufhidden=wipe`, `filetype=loomworks_description`
and `textwidth=0`. The title is `Description — <kind> <name>`. Its content is:

```
<current description, or empty>

# Describe profile 'Debug:ninja-clang-18.1.0'.
# The first line is the summary shown in lists; add a blank line, then details.
# Lines starting with '#' are ignored. Save an empty description to remove it.
# :w saves · :q! discards
```

- `:w` (BufWriteCmd) removes the `#` lines, normalises the text (core §1.10) and
  applies it:
  - an empty result **removes** the description;
  - an unchanged result writes nothing.

  After a save the buffer is marked unmodified and `:q` closes it; `ZZ` / `:wq`
  save and close.
- A refused description (a control character, or more than 4096 bytes) is
  reported inline as an error and the buffer stays modified.
- Closing without saving (`:q!`) discards the edit.
- The syntax highlights the summary line, marks the summary past 72 columns
  (`WarningMsg`, advisory only), and dims `#` lines. It does not use the
  `gitcommit` filetype, so commit-message plugins and ftplugins do not attach.
- Saving an edit to a `shared` item materialises it (core §2.4). A published
  item then shows `+`.
- On a generated configuration, `e` does not open the editor. It notifies that
  generated configurations take their description from the project files, and
  that a user configuration inheriting it can carry its own.

## 2. Highlight Groups

| Group                    | Default link      | Usage |
|--------------------------|-------------------|-------|
| `LoomworksActive`        | `DiagnosticOk`    | Active profile, active set |
| `LoomworksBuilt`         | `DiagnosticOk`    | Built configurations |
| `LoomworksConfigured`    | `DiagnosticInfo`  | Configured (not yet built) |
| `LoomworksUnconfigured`  | `Comment`         | Never configured |
| `LoomworksFailed`        | `DiagnosticError` | Failed configure or build |
| `LoomworksRunning`       | `DiagnosticWarn`  | Running tasks (non-active) |
| `LoomworksDeleting`      | `DiagnosticError` | Deletion in progress |
| `LoomworksUnknown`       | `DiagnosticWarn`  | Unknown state (partial deletion) |
| `LoomworksActionable`    | `Normal`          | Actionable items (sets, configs) |
| `LoomworksConflict`      | `DiagnosticWarn`  | Output-artifact conflict / overwritten unit (§1.5, §1.8) |
| `LoomworksDescription`   | `Comment`         | Description summaries and description lines (§1.16) |
| `LoomworksStale`         | `DiagnosticHint`  | `[stale — reconfigure]` hints, incl. the compiler-cache mismatch (§1.5); the `N suggestions` line (§1.1) |

Users can override these by defining the highlight groups before plugin load.

---

## 3. Winbar / Statusline Component

`lualine/components/loomworks.lua` provides a lualine component for
winbar display. Its data are the `loomworks.view.Header/1` and
`loomworks.view.ProjectsIndex/1` tables (daemon.md §19.13 "Views"; step 5j,
plan): the daemon's while the editor is subscribed, otherwise built
in-process with the same shape.

**Default display**: `{set_name} {join} {project}/{configuration}`

Where `{join}` defaults to `\u{e0b1}` (powerline thin right arrow) with
spaces.

**Configurable via `show` option**: array of parts to display:
- `"set_name"` — configuration set name
- `"project"` — project key for current buffer
- `"configuration"` — active configuration
- `"tool_key"` — tool key (e.g., the active profile's `tool_key`)

Every piece of workspace data the component inserts (set names, project keys,
configuration names, tool and profile keys, status) is made inert before it
reaches the statusline: control characters are removed and `%` is doubled to
`%%`, so a name from a cloned `loomworks.json` cannot inject statusline items,
highlight groups or expressions. The component's own highlight escapes, icons
and join string are not affected. This is the display-text rule of `specification.md` §17.11. The
component never shows descriptions.

**Returns empty** when:
- No workspace loaded
- No active profile
- Current buffer is not in any project
