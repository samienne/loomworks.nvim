# UI v2 — design draft

> **Status: design draft, not authoritative.** This file captures the v2
> UI design as it converges. Companion to
> [`v2-design-brief.md`](v2-design-brief.md) (requirements) and
> [`v2-design-scenarios.md`](v2-design-scenarios.md) (user flows). The
> current shipping UI is documented in [`ui.md`](ui.md); v2 does not
> replace it until v2 ships.
>
> When v2 ships, this file becomes the new `ui.md` and the brief +
> scenarios are archived or deleted (see brief §9).

---

## 1. Scope

This file describes:

- The information architecture of the v2 UI
- The interaction model (selection, edit, navigation)
- Per-surface contents (overview, inspector, activity/plan strip)
- Cross-cutting concerns (palette, hint bar, keybindings, notifications,
  fidget, winbar)
- What is preserved from v1 to satisfy "no regressions" (brief §4.9)

It deliberately does **not** specify:

- Concrete widget rendering (extmarks, highlight values, exact glyphs)
- Snacks API call sequences
- Implementation file layout

Those follow the IA, not the other way around (brief §8.6).

The data model, three-file model, module / LSP / DAP / SDK contracts,
and build/configure/launch/deploy semantics are unchanged from
[`../specification.md`](../specification.md) and the per-implementation
specs under [`spec/`](.). v2 redesigns *how the user interacts with the
existing model*, not the model itself.

---

## 2. Information architecture

### 2.1 Three persistent panes

The UI is opened by a single command/keymap (default `<leader>wo`) and
presents three docked panes:

```
┌───────────────────┬──────────────────────────────┐
│ Overview          │ Inspector                    │
│ (structural —     │ (selected item: edit-in-     │
│  active card +    │  place, live validation,     │
│  collapsed rest)  │  resolved-path preview)      │
├───────────────────┴──────────────────────────────┤
│ Activity / Plan strip                            │
│ (temporal: live tasks · plan: profile chain)     │
└──────────────────────────────────────────────────┘
```

Each pane is a Neovim window. Standard `<C-w>` operations resize, swap,
or close panes. Closing a pane does not destroy state — re-opening the
UI restores the layout.

The three panes are decoupled but coordinated:

- The overview drives selection. Cursor movement updates the inspector
  unless inspector is pinned (§4.1).
- The activity/plan strip is independent of selection — it tracks the
  workspace's runtime state (live mode) or the active profile's chain
  (plan mode).
- The hint bar at the bottom of each pane reflects the actions valid
  for that pane's current focus.

### 2.2 Compact mode

For viewports below a hard width threshold (~140 columns), or when the
user prefers it, the UI collapses to a single buffer with mode-switched
sections (overview · inspector · plan). This is functionally the same
components in a different presentation; nothing is unavailable in
compact mode.

Compact mode is selected by:

- User config option (`docked` | `compact`) for the preferred default
- Hard auto-fallback to compact when the viewport is too narrow for
  three panes regardless of preference

### 2.3 Command palette

The command palette is the canonical surface for:

- Creation actions (`Add project`, `Add configuration set`, `Add launch`,
  `Add deploy step`, `Add variable`, `Add profile`)
- Cross-cutting sweeps (`Workspace cleanup`, `Rescan tools`,
  `Rescan devices`, `Publish all modified items`)
- Action-from-anywhere shortcuts that don't have a dedicated keybind
  (`Switch to profile X`, `Inspect project Y`, `Activate device Z`)

The palette is reachable from any buffer (default `<leader>wp`),
including source files when the loomworks UI is closed. It is
implemented over `Snacks.picker` against a dynamic action source.

The palette doubles as the discoverability surface for advanced
features (brief §3.5): users find features by fuzzy-searching what
they're trying to do, even if they don't know the term.

### 2.4 Hint bar

Each pane has a persistent footer showing the keybindings and actions
valid for the current selection or focus. The hint bar updates as the
cursor moves; it never shows stale or pane-irrelevant actions.

The hint bar replaces the v1 pattern of appending hints to group
labels (`[Enter] activate [b] build …`), which suffered from
inconsistency — some nodes had hints, some did not.

The hint bar also surfaces **next-step nudges** during chain workflows
(§6). After committing an action that has a natural successor, the
hint bar offers it: e.g. after creating a project, the project
inspector's hint bar shows `[n] new set with this   [s] add to existing
set`.

---

## 3. Overview pane

### 3.1 Layout

The overview is **active-centric**: the most prominent region is the
active profile card, with everything else collapsed below.

```
┌─ Overview ────────────────────────────────────┐
│ MyWorkspace                              [+]  │
│ ────────────────────────────────────────────  │
│ ▶ Debug:ninja-gcc-12        ⏳ build 67%      │
│   set: Debug · target: App.debug              │
│                                               │
│   App           Debug          ✓ built        │
│   Frontend      development    ⏳ configuring │
│   NativeLib     Debug          ✗ configure   │
│ ────────────────────────────────────────────  │
│                                               │
│ Devices  (1 online · 1 offline)               │
│   FMR0225…  online   Mate 60 Pro              │
│   ABC1234…  offline                           │
│                                               │
│ ▶ Cleanup candidates  (3 · 1.2 GB)            │
│ ▶ Other profiles  (3)                         │
│ ▶ Other projects  (1 not in profile)          │
│ ▶ Configuration sets  (2)                     │
└───────────────────────────────────────────────┘
```

### 3.2 Active profile card

Always visible at the top. Composed of:

- **Profile header row**: profile key, state badge (✓ built · ⏳ running
  with progress · ✗ failed · ⚠ stale · — unconfigured), and an
  optional context line below (configuration set name, default target).
- **Participating projects**: one row per project in the active
  profile's mappings, showing the configuration mapped for this profile
  and the configuration's state.
- **Failure visibility**: a failed configuration's row is rendered with
  the failure highlight; the error message itself lives in the
  inspector (no inline error rows in overview).

When no profile is active, the card region is replaced by an
empty-state CTA (§3.7).

### 3.3 Devices

Visible only when at least one workspace module declares
`has_devices = true` (per core spec §1.8). For workspaces with no
device-capable modules the section is omitted entirely (not collapsed,
not "0 devices").

Each device row shows: serial (truncated), state (online/offline),
display name. Selecting a device opens the device inspector (§4.3.8).

### 3.4 Cleanup candidates

Visible whenever there are orphaned cached configurations or stray
build directories. Section header shows item count and total size.
Each row is one candidate (project/config orphan, stray dir) with
size and last-modified date when available.

Per-item delete via `D` from overview. The palette command
`Workspace cleanup` opens the workspace cleanup audit inspector
(§4.3.9), which surfaces the same items in a checklist with batch
confirmation.

### 3.5 Other profiles, other projects, configuration sets

Collapsed by default, count visible in the section header. Expand on
`<CR>` or `o` (open). These sections exist for the rare-but-real
cases of:

- Inspecting a profile that isn't currently active (e.g. to change its
  default target without activating it)
- Inspecting a project not in the active profile (e.g. to add it to
  a configuration set)
- Editing a configuration set's mappings without going via a profile

For switching the active profile, the palette / `<leader>ws` is the
expected path; the picker shows per-profile state (✓ built · ⚠ stale)
inline so comparison happens at switch time.

### 3.6 Section ordering

```
1. Active profile card                  (always present)
2. Devices (when relevant)              (workspace has device modules)
3. Cleanup candidates                   (when items exist)
4. Other profiles                       (collapsed)
5. Other projects                       (collapsed)
6. Configuration sets                   (collapsed)
```

Runtime sections come first; configuration sections come last.
Cleanup sits between because it is occasional but worth nagging via a
visible count.

### 3.7 Empty-state CTAs

When the workspace has no `loomworks.json` / `user.json` yet, or has
no projects, the overview shows actionable CTAs as content rather
than empty sections:

```
┌─ Overview ────────────────────────────────────┐
│ MyWorkspace (uninitialised)                   │
│ ────────────────────────────────────────────  │
│                                               │
│   + Add project from current directory        │
│   + Browse and add project                    │
│                                               │
│   palette: <leader>wp                         │
└───────────────────────────────────────────────┘
```

After the first project is added, the overview transitions to the
active-card form. The user is guided by the project inspector's
hint bar to the next step in the chain (§6.1). No wizards.

### 3.8 Visual treatment

Status conventions used across overview rows:

| State / kind | Treatment |
|--|--|
| Active profile | Highlight group + leading marker |
| Pinned-in-inspector item | Pin glyph on the row |
| Orphaned profile (set removed) | Dimmed + `[stale]` tag |
| Orphaned cached config | Listed in Cleanup candidates section |
| Configuration not configured | `—` placeholder, no state badge |
| Failed | Failure highlight on the row |
| Running | Spinner glyph + progress |
| Dimmed (loomworks.json-only items not yet in user.json) | Comment highlight |

Concrete glyphs and highlight group names are deferred to
implementation. The semantic categories above are stable.

---

## 4. Inspector

### 4.1 Selection model

The inspector follows the overview's cursor by default:

- Moving the cursor in overview to a different selectable item
  immediately updates the inspector to that item.
- Pressing `p` on an overview row pins the inspector to that item;
  subsequent cursor movement does not change the inspector. The
  pinned row gets a pin glyph in overview.
- Pressing `p` again on the pinned row (or on a different row)
  unpins / repins.

Pin enables comparison and "look at A while editing B" workflows
without modal traps. Edits commit only when the user explicitly saves
(`:w` on the inspector buffer); abandoning (`:q`) discards.

### 4.2 Component composition

Inspectors are composed from a small set of reusable components:

| Component | Purpose |
|--|--|
| `FieldGroup` | Labelled fields, edit-in-place, per-field validation |
| `OptionTree` | Collapsible group/leaf tree (cmake options, variables) |
| `MappingTable` | N×M mapping grid (config sets, profile mappings) |
| `WireForm` | 2-pane source/destination editor (deploy steps) |
| `Picker` | Inline `Snacks.picker` for value selection |
| `ProvenanceOverlay` | Virt_text annotation of value source ("from Debug") |

Each inspector kind is a thin composition of these components plus a
kind-specific data binding. Components are testable headlessly to
match v1's status renderer testability (brief §6.2).

### 4.3 Inspector kinds

The inspector is **specialised per selection kind**: each kind uses a
distinct composition of components tuned to the editing affordances
that kind needs. Common primitives are shared (4.2); per-kind layout
and field schema are defined here.

#### 4.3.1 Project

Shows project metadata, configurations, set membership, launch configs,
variables, project-level deploy. Set membership is read-only here — sets
are owned by themselves (§4.3.6) — but with action shortcuts:
`+ Add to existing set...` and `+ Create new set with this project`.

```
Inspector: App
  Type: cmake (auto-detected)
  Path: packages/app
  Configurations  (3 auto)            <CR> drills to config inspector
  Configuration set membership        + Add to existing  + Create new
  Launch configs                      <CR> drills to launch inspector
  Variables                           <CR> drills to variable inspector
  Deploy  (project-level)             <CR> opens wire mode
  Published: yes/no                   toggle field
```

#### 4.3.2 Configuration

Shows variant, inherits chain, options tree (`get_options`), toolchain,
generator, per-configuration deploy (when configuration-level deploy
ships per spec §8.8.6). Auto-generated configurations are read-only;
user configurations have edit/rename/delete actions.

#### 4.3.3 Profile

Shows the configuration set, tool, mappings (read-only — the source of
truth is the set), default target, default launch, device serial,
published flag. Mappings link to per-project context: `<CR>` on a
mapping row opens the project inspector for that project.

#### 4.3.4 Launch config

Shows command, args, env, working_dir, debug adapter list, deploy steps
(wire mode shortcut). Live `${...}` resolution preview as the user
types each field. Variables are editable inline; the picker for
deploy step source descriptors lists projects and their
configurations valid for the active profile.

#### 4.3.5 Deploy step (wire mode)

Two-pane form replacing the JSON-style nested editor of v1. Left pane
is the source picker (project → target / path); right pane is the
destination pattern with live-resolved preview. Phase (pre-build /
post-build) is an explicit, prominent radio — never a buried boolean.

```
Source                            Destination
┌─────────────────────────┬──────────────────────────────┐
│ project: NativeLib  ▾   │ ${build_dir}/native.node     │
│ target:  native_lib ▾   │ resolved: /work/.nvim/build/ │
│ ─ or ─                  │           App/Debug/native.node│
│ path:                   │                              │
│                         │ Phase: ( ) pre-build         │
│ configuration: (auto)   │        (•) post-build        │
└─────────────────────────┴──────────────────────────────┘
                  [save]   [cancel]
```

Pickers offer only valid (project, target) pairs from the active
profile. Validation runs at edit time — typos don't reach launch
(brief §3.1, scenario UC-DEPLOY-01/02).

#### 4.3.6 Configuration set (mapping table)

Single inspector form for both creation and editing:

```
Inspector: Configuration set "Debug"
  Name: Debug
  Mappings
    App         variant:Debug
    Frontend    development
    NativeLib   variant:Debug
    Legacy      —                   (unmapped — skipped in this set)
  Published: yes
```

Each row picks a configuration via `Snacks.picker` over the project's
canonical names (`variant:…`, `preset:…`, `auto:…`, user configs).
Rows may be left unmapped — the project is then skipped in this set.
No automatic mapping defaults; the user picks every row explicitly.

A new set is created via the palette (`Add configuration set`) or the
project inspector (`+ Create new set with this project` pre-populates
the new set's mapping for that project). Saving with zero mappings is
allowed (empty container the user fills later) but activate-time
warns if the set is still empty.

#### 4.3.7 Variable

Shows name, type (`string` | `path`), default value, per-configuration
overrides with provenance overlay (§4.2 — `ProvenanceOverlay`)
indicating which configuration each effective value comes from.

#### 4.3.8 Device

Shows serial, display name, provider module, state, properties dict.
Mostly read-only; actions include "pin to active profile",
"open log", "rescan".

#### 4.3.9 Workspace cleanup audit

Reachable via palette command `Workspace cleanup`. Lists all cleanup
candidates (orphaned cached configs, stray build dirs) with sizes and
last-modified dates, as a checklist with batch select. The same
items are also visible in overview's Cleanup candidates section
(§3.4); the audit inspector is the deliberate-sweep entry point.

Live profile build directories are never in the candidate list. The
confirmation dialog explicitly enumerates everything that will be
deleted (scenario UC-CLEAN-01).

---

## 5. Activity / plan strip

The bottom strip toggles between two modes. Mode is sticky until
explicitly toggled.

### 5.1 Live activity mode

Default mode. Shows currently-running tasks and the most recent task
results. Each entry: task name, owning ConfigUnit (or operation),
state (running with progress · completed · failed), duration.

This mode replaces visible fidget popups while the UI is open
(§7.3) — same data, richer view.

### 5.2 Plan mode

Shows the active profile's full execution chain:

```
Plan: Debug:ninja-gcc-12 → App.debug
  ├ build deps
  │   NativeLib                  ✓ fresh   built 12:04:11
  ├ pre-build deploy
  │   App/entry/libs/arm64-v8a/  ✓ fresh   from NativeLib
  ├ build self
  │   App                        ⏳ 67%
  ├ post-build deploy
  │   ${build_dir}/native.node   — pending
  ├ install
  │   FMR0225…                   — pending
  └ launch
      App.debug                  — pending
```

Per-step state: ✓ fresh · ⚠ stale · ⏳ running · ✗ failed · — pending.
`<CR>` on a step jumps the inspector to that step's source (config
unit, deploy descriptor, launch config) for fast diagnosis.

Plan mode answers "what will happen if I build now?" and "why didn't
my .so end up in the HAP?" without modal navigation (brief §3.2,
scenarios UC-DEPLOY-01/02, UC-DEVICE-01).

### 5.3 Mode toggle

A single keybinding in the strip toggles between live and plan modes.
Plan mode is also auto-engaged when the user explicitly hovers a
non-active profile in overview's "Other profiles" section — the strip
shows that profile's plan with no commitment to activate it.

### 5.4 Open question — granularity

Plan rows for "build deps" can be collapsed to a single row or
expanded to one row per dependency project. Both are renderable;
choice deferred until usable prototype testing.

---

## 6. Setup chain workflows

The setup chain (project → configuration set → activate) is explicit;
the system does not auto-create sets or auto-map projects (history
showed `map_variant`-driven defaults guess wrong often enough to be
removed). Each step is its own short inspector form, committed
independently. Chain fluidity comes from the inspector's hint bar
nudging the natural next step.

### 6.1 First project in an empty workspace

1. User opens the UI; overview shows empty-state CTAs (§3.7).
2. User invokes `+ Add project` (CTA, palette, or `<leader>wp` →
   `Add project`).
3. Inspector opens a new-project form: path (with type detection),
   type, name. Save.
4. Inspector switches to the new project inspector. The project's
   set membership is empty.
5. Hint bar offers `[n] new set with this   [s] add to existing set`.
6. User presses `n`. A new configuration set inspector opens with
   this project's row pre-populated (§4.3.6).
7. User names the set, picks the variant for this project, saves.
8. Hint bar on the saved set offers `[a] activate`.
9. User activates → the system materialises a profile (mechanism
   unchanged from v1) and sets it active.
10. `<leader>wb` builds.

Approximately ~8 keystrokes from cold workspace to first build. No
automation, no wizard, every intermediate state is independently
useful (brief §3.4 — abandoning mid-chain leaves a usable workspace).

### 6.2 Adding a project to an existing workspace

Same as 6.1 steps 1–4. Then:

5. Hint bar offers `[s] add to existing set` (and `[n] new set` as
   before).
6. `s` opens a picker over existing sets. After selection, a
   configuration picker over this project's canonical names commits
   the mapping.
7. The set inspector reflects the new mapping; activation is unchanged.

There is no auto-extend: existing sets are not silently mutated when
a new project is added. The new project simply has empty membership
until the user maps it.

### 6.3 Profiles always require a configuration set

Per spec §1.6, every profile is set-based; pinned profiles (no set)
are not supported. v2 surfaces this by routing all profile creation
through configuration set activation. There is no "Add pinned
profile" entry in the palette.

Profile-level edits (default target, default launch, device serial,
published flag, custom kit selection) happen on the profile inspector
(§4.3.3) once the profile exists.

---

## 7. Cross-cutting concerns

### 7.1 Keybindings

#### Convention

- `<leader>w` is the loomworks prefix. `<leader>t` is loomtest's
  prefix and is not within the scope of this file.
- Lowercase letters are the default action; capital letters are the
  "alternative". For run/debug pairs the lowercase variant is the
  debug-augmented one (`<leader>wr` runs under debugger, `<leader>wR`
  runs without).
- `k` is reserved for Neovim navigation and is not bound by the
  loomworks UI in any pane.

#### Global (work from any buffer)

| Binding | Action |
|--|--|
| `<leader>wo` | Open the loomworks UI |
| `<leader>wp` | Open the command palette |
| `<leader>wb` | Build (default target if pinned, otherwise full profile) |
| `<leader>wB` | Build full profile (alternative) |
| `<leader>wc` | Configure active profile |
| `<leader>ws` | Switch profile (picker) |
| `<leader>wr` | Run default target under debugger |
| `<leader>wR` | Run default target without debugger |
| `<leader>wd` | Device picker / device log |
| `<leader>wx` | Stop running target |
| `<leader>wj` | Inspect project owning current buffer |

#### In the UI

| Binding | Pane | Action |
|--|--|--|
| `<CR>` | overview | Drill into selection (open inspector) / activate as appropriate |
| `j` / `h` / `l` | overview, inspector, strip | Navigate |
| `o` | overview | Toggle section collapse |
| `b` | overview | Build the focused profile |
| `c` | overview | Configure the focused profile |
| `D` | overview | Delete (profile / config / cleanup item) — confirm |
| `C` | overview | Clean (profile / config) — confirm |
| `p` | overview | Pin / unpin inspector to focused row |
| `:w` | inspector | Save edits |
| `:q` | inspector | Discard edits |
| `<Tab>` | inspector | Next field |

Publish toggling moves to a field within the inspector (§4.3); there
is no overview-level publish keybind. Mass publish is in the palette
(`Publish all modified items`).

### 7.2 Notifications policy

| Event | Notification | Other surfaces |
|--|--|--|
| Build / configure success (routine) | None | Active card state, fidget on close |
| Build / configure failure | One notification | Active card red, inspector shows error |
| Operation completed (delete/clean) | One notification | Cache state reflected in overview |
| Edit-time validation error | None | Inline in inspector |
| Adapter not installed (debug) | One notification (Mason hint) | — |
| Tool detection complete | None | Configuration sets section refreshes |

Routine successes do not steal user attention (brief §3.5,
scenario UC-DAILY-01).

### 7.3 Fidget integration

Fidget continues to display live task progress when the loomworks UI
is **closed**. While the UI is **open**, fidget popups are suppressed
to avoid duplicating the activity strip's signal. The activity strip
and fidget show the same source data; the strip is the richer view
when the UI is up.

### 7.4 Winbar

The buffer-local winbar component stays as in v1: shows the active
configuration for the buffer's owning project. v2 may add a subtle
indicator when the buffer's project is the inspector's currently
pinned subject, but this is not load-bearing.

---

## 8. Validation and live preview

Edit-time validation is the v2 answer to the v1 pattern of "type
something, save, discover at launch time it's wrong" (brief §3.1,
§3.4).

Wherever an inspector field accepts:

- A path with `${...}` expansions
- A reference to another project / target / configuration / variable
- A typed value (path, integer, choice from a fixed set)

…the inspector renders the resolved value (or the validation error)
in real time, typically as virt_text adjacent to the cursor. Commit
is blocked only by hard errors (broken reference, malformed path);
soft warnings (e.g. `${variant}` vs `${configuration}` confusion)
render in the hint bar without blocking commit.

Variable name confusion and `..`/`.` path safety are flagged at edit
time, not at parse-time after the dialog closes.

---

## 9. What v2 preserves from v1

Per brief §4.9, v2 must not regress capability. The following stay
expressible:

| v1 capability | v2 surface |
|--|--|
| Publish / working-copy model (`+` indicators, `:w`) | Inspector publish field, modified indicators in overview, `:w` on the workspace header item |
| Profile activation | `<CR>` on profile / palette / `<leader>ws` |
| Deploy steps with merge rules | Wire mode (§4.3.5), project + launch level, pre/post phase |
| Device selection per profile | Profile inspector field + device picker |
| Debug adapter selection | Launch inspector field |
| Profile-level type config edits | Configuration inspector |
| Orphaned cached configs | Cleanup candidates section + audit inspector |
| Stale profile (set removed) | `[stale]` tag on the profile row |
| Tool detection state | Section refresh on `tools_detected`; `<leader>wp` → `Rescan tools` |
| Per-buffer winbar | Unchanged |
| Highlight group names | Public contract; preserved |
| Public `require("loomworks")` API | Public contract; preserved |

---

## 10. Open questions / deferred decisions

The following are not blocking on the IA but need resolution before
implementation:

1. **Plan-row granularity for "build deps"**: collapsed to one row or
   expanded per dep project. Decide via prototype testing.
2. **Project-level deploy editing**: nested in the project inspector
   or its own kind. Decide via prototype testing.
3. **Compact-mode shape**: the exact mode-switch layout for
   sub-threshold viewports. Could ride along with implementation.
4. **`<S-K>` hover popup**: explicit hover binding for inspecting an
   item without moving cursor / pinning. Defer until proven useful.
5. **Concrete glyphs and highlight groups**: inherited semantically
   from v1, refreshed at implementation time.
6. **Modified indicator (`+`) bubbling**: keep the v1 bubble-up rule
   (parent shows `+` if any child modified) — confirmed; details
   on visual placement TBD.
7. **Cleanup section default state**: collapsed with count badge
   (current draft) vs expanded when items present. Lean: collapsed.

---

## 11. Validation against brief

Cross-check of the v2 design against the brief's binding goals (§2)
and capabilities (§4):

| Brief item | v2 mapping |
|--|--|
| Goal §2.1 — Frequent tasks ≤ 1 keystroke | Global keybindings + palette (§7.1) |
| Goal §2.2 — Complex tasks without ceremony | Wire mode (§4.3.5), chained inspectors (§6) |
| Goal §2.3 — Persistent context | Three-pane layout (§2.1), inspector replaces modals (§4) |
| Goal §2.4 — Visible relationships | Plan mode (§5.2), set mapping table (§4.3.6) |
| Goal §2.5 — Fast feedback on edits | Live preview / validation (§8) |
| Goal §2.6 — Information at right density | Active-centric overview (§3), inspector for depth |
| Capability §4.1 — Plan view | Plan mode (§5.2) |
| Capability §4.2 — Live edit feedback | §8 |
| Capability §4.3 — Multi-project visualization | Plan mode + set mapping table |
| Capability §4.4 — Action-from-anywhere | §7.1 global bindings + palette |
| Capability §4.5 — Persistent context | §2.1 |
| Capability §4.6 — Early validation | §8 |
| Capability §4.7 — Inspector pattern | §4 |
| Capability §4.8 — Discoverable advanced features | Palette (§2.3) |
| Capability §4.9 — No regressions | §9 |
| Capability §4.10 — Status page entry | `<leader>wo` (§7.1) |

Pain inventory cross-check:

| Pain (brief §3) | v2 resolution |
|--|--|
| Deploy typos surface late | Wire mode + live validation (§4.3.5, §8) |
| `${variant}` vs `${configuration}` | Live preview + soft warning (§8) |
| Path `..` rejected at parse time | Inspector validates at edit time (§8) |
| No flow visualization | Plan mode (§5.2) |
| Deploy freshness invisible | Per-step state in plan mode |
| Pre/post-build phase hidden | Explicit radio in wire mode (§4.3.5) |
| Tree-only IA | Three-pane workbench (§2.1) |
| Modal-driven editing | Inspector pattern (§4) |
| Discoverability of advanced features | Palette (§2.3) |

---

## 12. Disposition

When v2 ships:

- This file replaces [`ui.md`](ui.md).
- [`v2-design-brief.md`](v2-design-brief.md) and
  [`v2-design-scenarios.md`](v2-design-scenarios.md) are archived or
  deleted per their own disposition notes.
- Pain points solved by v2 do not need to be remembered.

If v2 does not ship:

- Delete this file. The current `ui.md` remains authoritative.
