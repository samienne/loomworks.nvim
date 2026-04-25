# UI v2 — design brief

> **Status: design input only.** This file is not authoritative spec. It
> is the requirements package for a future fresh-context design session
> that produces a v2 UI. If v2 ships, this file archives. If v2 doesn't
> pan out, delete it.
>
> The current UI is documented in [`spec/ui.md`](ui.md). v2 is permitted
> to redesign anything that file describes — its content is not load-bearing
> for v2.

---

## 1. Why a v2

The current UI evolved feature-by-feature: status page → profile
management → config sets → projects → launch configs → deploy steps →
device interface → debug adapters. Each addition fit into the existing
tree-and-dialog shape. The result works but has accumulated:

- **One tree, all topics.** Switching attention between deploy state and
  project state means scrolling and folding through unrelated sections.
- **Dialog-heavy editing.** Modal dialogs hide the surrounding state;
  once dismissed, the user must re-navigate to verify the result.
- **Single linear access path.** Frequent tasks (build, switch profile)
  and rare tasks (edit a deploy step) take similar amounts of friction.
- **No 2D space usage.** Everything is vertical lists. Relationships
  between projects (deploy flows, config-set mappings, dependency
  chains) are buried in JSON keys.

A v2 should reset the IA assumptions and design from user intent rather
than incremental accretion.

---

## 2. Goals

The v2 design must hit all of these:

1. **Frequent tasks ≤ 1 keystroke from anywhere.** Build the active
   profile. Switch profile. Open a config's options. Run nearest test.
   These should not require first navigating to a specific tree node.
2. **Complex tasks possible without ceremony.** Defining a deploy step
   that bundles a built artifact into a downstream package shouldn't
   require six dialog hops.
3. **Persistent context.** No modal traps. The user should always be
   able to see workspace state while editing.
4. **Visible relationships.** When data flows between projects (deploy
   steps, configuration set mappings, profile composition), those flows
   should be visible somewhere — not implied by JSON keys.
5. **Fast feedback on edits.** Path expansion, validation, "what would
   happen if I committed this" — surface immediately during editing,
   not at execution time.
6. **Information at the right density.** Default view answers
   "what's the workspace doing right now?" Power users can drill into
   any subsystem without losing the overview.

---

## 3. Pain inventory

Concrete failure modes observed in real use of the current UI. v2 must
either solve these or have a deliberate reason not to.

### 3.1 Deploy step definition

Today: edit JSON manually or open the deploy editor dialog. Type project
key, target name, destination path with `${...}` variables, save, hope.

Failures:

- Typos in project key or target name surface only at launch time as
  "deploy: target X not found"
- `${variant}` vs `${configuration}` look interchangeable; the user
  learns the difference by failure
- Path with `..` is rejected at parse time only, not at edit time
- No live preview of the fully-resolved destination path
- Multi-source array form is documented but easy to misformat
- Pre-build vs post-build phase is one boolean buried in a source
  descriptor; users forget to set it for native-into-HAP cases

### 3.2 Multi-project flow visualization

Today: there is no place that shows the full execution sequence
("for this profile: build deps → pre-build deploy → build self →
post-build deploy → install on device → launch") with current state
per step.

Failures:

- "Why isn't my .so in the HAP?" — the JSON answers it but no view
  shows the answer at a glance
- Deploy freshness is invisible; users learn the file is stale by
  launching and observing wrong behavior
- Pre-build vs post-build ordering is invisible; the user has to
  mentally simulate the chain

### 3.3 Tree-only IA

Today: the status page is one tree with five sections (Profiles,
Orphaned Items, Config Sets, Projects, plus the header). To compare
two profiles, fold/unfold/scroll.

Failures:

- Switching attention between "what's running" and "what could I run
  next" requires scrolling
- No inspector pattern; the place that displays an item is also the
  place that edits it
- Floats and dialogs cover the tree, hiding surrounding state during
  edits

### 3.4 Dialog-driven editing

Today: every editable field opens a `vim.ui.input` or `vim.ui.select`
modal. Multi-field edits chain dialogs.

Failures:

- Validation errors require dismissing and reopening the dialog
- No "preview before commit" — you commit, see the result in the tree,
  then maybe undo
- Cancelling halfway through chained edits loses intermediate state
- Modal dialogs hide the workspace state the user is editing against

### 3.5 Discoverability of advanced features

Today: deploy steps, project variables, debug adapter selection,
device picker — all reachable but only if you know they exist.
Sentinel lines (`▸ Add ...`) help, but only show up at the bottom of
relevant sub-trees.

Failures:

- New users don't discover deploy steps until they hit a specific
  multi-project use case
- No help-driven path "I want to ship X to a device — show me how"

---

## 4. Capability wishes

Things v2 must support, regardless of its visual shape. These are
*invariant* requirements — failure on any of these means v2 is not
ready.

1. **Plan view.** Display a complete profile's execution sequence —
   build deps, pre-build deploy, build self, post-build deploy, install,
   launch — with per-step state (fresh / stale / unknown / running /
   failed) and last result.
2. **Live edit feedback.** Whenever a path or reference is being edited
   (deploy step, launch config, variable), show the fully-resolved
   value in real time and validate references against the workspace.
3. **Multi-project visualization.** Show how projects relate within a
   profile: configuration set mappings, deploy flows, dependency edges.
4. **Action-from-anywhere.** Frequent actions (build, configure, switch
   profile, debug, run nearest test) reachable without first navigating
   to a node.
5. **Persistent context.** No state lost because the user opened an
   editor. Tree / overview / current selection remain visible.
6. **Early validation.** Orphan project keys, missing targets, broken
   `inherits` chains, unresolvable deploy paths — all surfaced at edit
   time, not at execution time.
7. **Inspector pattern.** Select something → see its details + actions
   in a dedicated area, distinct from the navigation surface.
8. **Discoverable advanced features.** Some surface (palette, hint
   bar, contextual menu) that lets a user find "I want to do X" without
   knowing the term for X.
9. **No regressions.** Everything currently expressible (publish/working
   copy, profile activation, deploy steps with all merge rules, device
   selection, debug adapter selection, profile-level type config edits)
   must remain expressible.
10. **Status page entry.** A single command / keymap that opens "the
    main loomworks UI", whatever shape it takes.

---

## 5. Directional ideas

Non-prescriptive. Directions worth investigating during the design
session, *not* designs to implement. If a directional idea conflicts
with a goal (§2) or capability (§4), the goal wins. If the design
session finds a better answer, throw these away.

### 5.1 Deploy as a graph

Projects as nodes, deploy steps as arrows from source artifact to
destination. A 2D layout makes "lib goes into HAP before assembly"
visually obvious instead of buried in nested JSON. Broken edges
(typo'd target, missing project) light up immediately. Pre-build vs
post-build distinguish via line style or arrow direction. The graph
is a *view*; JSON stays canonical.

### 5.2 Two-pane source/destination wire mode

For editing deploy steps: left pane lists sources (projects → their
build targets / declared artifacts / known build outputs); right pane
lists destination patterns. Pick from each, commit a step. Variable
expansion preview shown live. Replaces three layers of nested dialogs.

### 5.3 Persistent inspector panel

Replace modal dialogs with a side panel that updates on selection.
Selecting a launch config fills the inspector with editable fields
(command, args, env, deploy). Selecting a project fills it with
project metadata + configurations. The tree / navigation surface
never disappears.

### 5.4 Profile execution plan view

Activating or hovering a profile activates a plan view showing the
ordered execution sequence with current state per step. Each step
shows: name, state (built / stale / running / failed), last result,
blocking errors. Replaces "press build, watch progress, hope" with
"see exactly what will happen and why."

### 5.5 Multi-pane layout

```
┌─────────────────────────┬─────────────────────────┐
│ Workspace overview      │ Inspector / detail      │
│ (projects, profiles,    │ (varies by selection)   │
│  active state, alerts)  │                         │
├─────────────────────────┴─────────────────────────┤
│ Active flows / tasks (live progress + history)    │
└───────────────────────────────────────────────────┘
```

Three regions covering structure, focused detail, runtime activity.
Each region has its own scroll/fold state. Resize via vim window
operations.

### 5.6 Command palette

Fuzzy-find action regardless of current view. "Build active",
"Switch profile to Release", "Edit deploy steps for App",
"Show device log". Replaces "navigate to the right node first" for
frequent actions. Discoverability bonus: surfaces advanced features
by name search.

### 5.7 Live resolved-path preview

Wherever a path with `${...}` is being edited, show the fully-expanded
version in real time. Same for source descriptors: as the user types
a project key, autocomplete from valid projects; as they pick a
target, show the resolved artifact path under it.

### 5.8 Contextual hint bar

Replace the "[Enter] activate [b] build [c] configure …" hint pattern
that's currently appended to group labels. A persistent hint bar at
the bottom shows actions valid for the current selection. Updates as
selection moves. Removes the inconsistency where some nodes show
hints and others don't.

---

## 6. Constraints

### 6.1 Hard

- **Neovim-native rendering.** Floats, splits, extmarks, virt_text,
  highlight groups. No external GUI process, no embedded webview.
- **Snacks** is available (already a hard dep) — `Snacks.win` for
  windows / floats, `Snacks.picker` for dynamic source pickers.
- **Overseer** is available — task tracking, output buffers,
  background tasks.
- **No new heavy dependencies.** Adding a tree-widget framework or a
  node-graph library is a high bar; default answer is no.
- **Keyboard-first.** Every action reachable by keyboard. Mouse
  support is bonus.
- **Single command entry.** A user keymap (default `<leader>wo` /
  current behavior) opens "the main UI" regardless of internal shape.

### 6.2 Soft

- Avoid relying on terminal features (true color, mouse, fancy
  border characters) that some users disable. Should degrade
  reasonably.
- Performance: smooth interaction with workspaces of 20+ projects
  and ~200 cached configurations.
- Test surface: components should be testable headlessly the way
  status renderer is today.

---

## 7. Out of scope

v2 is **not** redesigning:

- The underlying domain model (Workspace, Project, Configuration,
  Profile, ConfigUnit, Device, SDK) — frozen by core spec §1.
- Three-file model (loomworks.json / user.json / cache.json) —
  frozen by core spec §2.
- Module / LSP / DAP / SDK contracts — frozen by their respective
  spec files.
- Build / configure / launch / deploy semantics — same Future-based
  chain, same lifecycle states. v2 visualizes them differently;
  it does not redefine them.
- The public API surface (`require("loomworks")` functions, events,
  highlight group names) — public contract.

The redesign is purely about *how the user interacts with the
existing model*.

---

## 8. Workflow notes for the design session

The fresh-context session that turns this brief into a v2 design
should follow this order:

1. **Read the core spec first.** `specification.md` §1–§5 for the
   data model, §6 (UI pointer) for confirmation that this brief is
   the design input, §8–§11 for the integration contracts, §15 for
   invariants. Do not read `spec/ui.md` until step 4.
2. **Read this brief.** Treat goals (§2) and capabilities (§4) as
   binding. Treat directional ideas (§5) as advisory.
3. **Read** [`spec/v2-design-scenarios.md`](v2-design-scenarios.md)
   if it exists — concrete user-flow examples to design against.
4. **Read `spec/ui.md`** *only as a reference* for behaviors that
   must be preserved (capability §9). Do not let its visual shape
   anchor the new design.
5. **Produce IA + interaction model first.** What surfaces exist?
   What lives where? How does the user move between surfaces? This
   is the harder problem.
6. **Widget / keybind / rendering specifics second.** These follow
   from the IA, not the other way around.
7. **Validate** the design against goals (§2), capabilities (§4),
   and pain inventory (§3). For each pain item, the design either
   solves it or has a documented reason not to.

---

## 9. Disposition after v2

If v2 ships:
- This file moves to a historical-notes location or is deleted.
- `spec/ui.md` is rewritten from scratch to describe v2.
- Pain points solved by v2 do not need to be remembered.

If v2 doesn't pan out:
- Delete this file. The current UI is fine; it just had a possible
  alternative explored.

Either way, this file is *not* a long-term maintenance burden. It
exists to bridge the design phase, and it dies when the design phase
ends.
