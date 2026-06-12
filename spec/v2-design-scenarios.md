# UI v2 — design scenarios

> **Status: design input only.** Companion to
> [`v2-design-brief.md`](v2-design-brief.md). These scenarios describe
> what users are trying to *accomplish*, intentionally without
> prescribing UI shape. They feed the v2 design session and the future
> integration test bank.
>
> Disposition: scenarios that become integration tests migrate into
> the test suite. Scenarios that purely informed UX decisions are
> deleted after v2 ships. Don't maintain this file as living docs.

---

## Format

Each scenario:

- **Id** — stable identifier, used for cross-references and future
  test names
- **Goal** — what the user is trying to accomplish
- **Preconditions** — assumed workspace state
- **Steps** — described as user intent, not UI actions
- **Expected outcome** — what the user observes / what state changes
- **Failure modes** — what should *not* happen (also test cases)

The "Steps" field is deliberately UI-agnostic. "User picks a profile"
is fine; "user presses Enter on the second tree node" is not.

---

## UC-SETUP-01 — First-time setup

**Goal:** Take a directory of source code (a single cmake project) to
"I can build it" in under a minute.

**Preconditions:**
- Working directory contains a `CMakeLists.txt`
- No `.nvim/`, no `loomworks.json`, no `loomworks.user.json`
- ninja and gcc available on PATH

**Steps:**
1. User opens the loomworks UI in the project root
2. User initialises a workspace
3. User adds the cmake project as a project
4. User configures the project

**Expected outcome:**
- `.nvim/loomworks.user.json` exists with one project entry, one
  configuration set with auto-detected mappings, one profile
- The cmake project shows configured state with a build directory and
  a tool selection
- User can immediately trigger build from the UI

**Failure modes (must not happen):**
- Asking the user for any data the system can detect
- Failing silently on missing tools — surface the missing-tool reason
- Creating cache state for a project that wasn't successfully added

---

## UC-DAILY-01 — Active build cycle

**Goal:** During a coding session, build the active profile after
editing source. Repeated dozens of times per hour.

**Preconditions:**
- Workspace loaded with at least one configured profile
- An active profile selected
- User is editing a source file in any project

**Steps:**
1. User triggers "build active" from the editor (no UI navigation)
2. Build progress is visible without obstructing the editor
3. On completion, build result is visible

**Expected outcome:**
- Build runs against the correct configuration
- Progress information visible without stealing focus
- Failure surfaces with enough detail to start fixing the bug
- On success, no notifications steal user attention

**Failure modes:**
- Requiring the user to first open the status UI
- Hiding build progress until completion
- Notifications for routine successes

---

## UC-SWITCH-01 — Profile switch without spurious rebuild

**Goal:** Switch between Debug and Release profiles. Each profile has
its own build directory; the previous build for either profile should
not be invalidated.

**Preconditions:**
- Two profiles exist: `Debug:<tool>` and `Release:<tool>`
- Both have been previously built
- One is active

**Steps:**
1. User makes the other profile active
2. User triggers a build

**Expected outcome:**
- The newly active profile builds incrementally (no full rebuild)
- The previously active profile retains its build state
- The active selection persists across nvim restarts

**Failure modes:**
- Spurious "stale" markers on the previously active profile
- Switching active also clearing freshness state for either profile
- Active selection lost after restart

---

## UC-DEPLOY-01 — Cross-project deploy step (post-build)

**Goal:** Build a native cmake library and copy its `.node` artifact
into a TypeScript app's runtime tree before launching the app.

**Preconditions:**
- Workspace has a cmake project (`NativeLib`) producing a `.node`
  target named `native_lib`
- Workspace has a typescript project (`App`) with a `debug` launch
  config that runs `node assets/scripts/app.js`
- A configuration set maps both projects to a buildable variant
- A profile is active for that configuration set

**Steps:**
1. User declares: "when launching `App.debug`, ensure `NativeLib`'s
   `native_lib` artifact lands at `${App.build_dir}/native.node`
   before launch"
2. User triggers launch of `App.debug`

**Expected outcome:**
- `NativeLib` builds (as a dependency)
- The artifact is copied to the destination
- `App` launches with the artifact in place
- On subsequent launches, the artifact is only re-copied when its
  source has changed
- Editing the source descriptor (project key, target name, destination)
  surfaces typos / unresolvable references *during editing*, not at
  launch time

**Failure modes:**
- Launch proceeds with a stale or missing artifact
- Typo in `target` name surfaces only at launch
- Multiple copies on every launch when source unchanged

---

## UC-DEPLOY-02 — Pre-build deploy (artifact as build input)

**Goal:** Build a cmake-produced `.so` and place it in a downstream
cmake project's source tree *before* that project's build, so the
downstream build picks it up as an input (e.g., bundling a generated
shared library into an executable's `assets/` directory before its
build step packages them).

**Preconditions:**
- Workspace has a cmake project (`NativeLib`) producing a `.so`
- Workspace has a second cmake project (`App`) whose build step
  expects the `.so` at `App/assets/native/`
- A profile is active

**Steps:**
1. User declares: "when launching `App`, copy `NativeLib`'s `.so`
   into `App/entry/libs/${abi}/` *before `App` builds*"
2. User triggers a build (or launch) of `App`

**Expected outcome:**
- Execution order: `NativeLib` builds → `.so` copied → `App` builds
  with the `.so` present → install / launch
- The pre-build vs post-build distinction is visible somewhere — not
  hidden in a boolean
- If the user marks the wrong phase (post-build for a build-input),
  the system either warns at edit time or recovery is one undo away

**Failure modes:**
- App builds before the `.so` is in place
- The pre-build flag is set on a source descriptor but the user can't
  tell from the UI without expanding it
- A second source under the same destination unintentionally
  overrides the first

---

## UC-DEVICE-01 — Launch and follow output

**Goal:** Build a cmake executable, launch it, and watch its stdout in
a non-disruptive view.

**Preconditions:**
- Workspace has a cmake project that produces an executable
- A profile is active
- A launch target is configured for the executable

**Steps:**
1. User triggers "Launch" for the configured target
2. Build runs
3. Process launches
4. Output stream starts

**Expected outcome:**
- Build + launch succeed; a single status surface shows progress
- Output view appears non-disruptively (does not hijack the editor)
- Lines from the launched process are visible
- When the process exits, the output stream and tracked run clear
  automatically

**Failure modes:**
- User has to manually dispose the output task to recover editor
  responsiveness
- Output stream mixes in stale entries from before the launch
- Stop action only closes the local view without terminating the
  process

---

## UC-DIAGNOSE-01 — Failed build diagnosis

**Goal:** A build fails. The user wants to see what failed and why,
without spelunking through overseer or task lists.

**Preconditions:**
- A profile is active and configured
- The user just attempted a build that failed
- An overseer task captured stderr/stdout

**Steps:**
1. User looks at the UI to see the failed state
2. User drills into the failed configuration

**Expected outcome:**
- Failure is immediately visible from the workspace overview (not
  buried in a sub-tree fold)
- Failed configuration shows last error message inline
- One action away: open the full task output to read the error in
  context
- Re-running the build does not require re-navigating to the failed
  node

**Failure modes:**
- Failure visible only after expanding multiple levels
- Last task output is disposed by the time the user looks
- No way to retry without first repositioning the cursor

---

## UC-EDIT-01 — Edit a configuration option

**Goal:** Toggle a cmake option (e.g., `BUILD_TESTS`) on the active
profile's configuration, then reconfigure to apply.

**Preconditions:**
- A profile is active and configured
- The configuration has at least one user-facing option

**Steps:**
1. User opens the configuration's options
2. User toggles one option
3. User triggers reconfigure

**Expected outcome:**
- Options are browsable as a tree of groups + options
- Toggle is reflected immediately in the UI
- Reconfigure runs with the new option value
- The change persists in the appropriate file (user.json / cache as
  applicable)
- After reconfigure, the option's new state is visible without
  manual refresh

**Failure modes:**
- Browsing options requires multiple keystrokes
- Toggle silently fails because the project has no `get_options`
  support — should be visibly disabled / unavailable instead
- Reconfigure loses the toggle because of a save-vs-merge race

---

## UC-EDIT-02 — Edit deploy steps with confidence

**Goal:** Add or modify a deploy step on a launch config and feel
confident it'll work before launching.

**Preconditions:**
- A profile is active
- A launch config exists on a project
- Cross-project knowledge: at least one other project with a known
  buildable target

**Steps:**
1. User opens the launch config's deploy steps
2. User adds a new step: source = `OtherProject` / target =
   `some_target`, destination = `${build_dir}/sub/`, pre-build = no
3. User reviews the resolved destination and source paths
4. User commits

**Expected outcome:**
- Source pickers offer only valid (project, target) pairs from the
  current profile
- Destination shows fully-expanded path during editing (no `${...}`
  remaining)
- Variable name confusion (`${variant}` vs `${configuration}`) is
  either prevented (single canonical name) or surfaced as a warning
  if both are referenced inconsistently
- On commit, the step is visible in context (not hidden behind
  re-navigation)
- On next launch, the step executes with the values the user saw at
  edit time

**Failure modes:**
- User commits a typo because there was no validation at edit time
- User commits a path with `..` and the rejection happens at parse
  time after the dialog closed
- The user has to launch to discover the step doesn't resolve

---

## UC-DEBUG-01 — Debug an executable target

**Goal:** Set a breakpoint in source code and start a debug session
for the active launch target.

**Preconditions:**
- nvim-dap installed
- A profile is active
- Launch target is debuggable (has a known language with an
  installed adapter)
- Source file is open with at least one breakpoint

**Steps:**
1. User triggers "debug active target"
2. Build (if needed) + deploy (if any) chain runs
3. Debug session starts at the entry point or breakpoint
4. User steps through code

**Expected outcome:**
- Same chain that launch runs, but final step is debug not run
- DAP session attaches with breakpoints honored
- Adapter not-installed surfaces as actionable error (Mason hint),
  not silent fallback to non-debug launch
- Multi-adapter launch configs (e.g., language A primary + language
  B attach) attach both debuggers to the same process

**Failure modes:**
- Debug silently falls back to non-debug launch when adapter is
  missing
- Multi-adapter launch only attaches the primary
- Build / deploy chain bypassed because debug is "different"

---

## UC-CLEAN-01 — Clean up after exploration

**Goal:** After experimenting with multiple profiles and configurations,
clean up anything that's no longer reachable from the current config.

**Preconditions:**
- Workspace has accumulated orphaned cached configurations and stray
  build directories from previous experiments
- Some build directories belong to live profiles, others don't

**Steps:**
1. User opens the cleanup view
2. User reviews what is candidate for removal
3. User confirms deletion

**Expected outcome:**
- Live state and orphaned state are clearly separated
- User sees concrete paths and sizes (or last-modified dates) for
  what would be removed
- Confirmation dialog explicitly lists everything that will be deleted
- Live profiles' build directories are *never* in the cleanup list
- Deletion is reversible only through git / filesystem-level recovery
  — UI does not pretend it's reversible

**Failure modes:**
- Live build directory included in cleanup candidates
- Deletion proceeds without showing what will be deleted
- Stray detection misses a directory or includes a sibling project's
  directory

---

## Cross-cutting concerns surfaced by these scenarios

The scenarios above expose a few patterns the v2 design must handle:

- **Chain visualization** (UC-DEPLOY-01, UC-DEPLOY-02, UC-DEVICE-01,
  UC-DEBUG-01). Many flows are sequences with per-step state. The
  user wants to see what will happen and what did happen.
- **Cross-project references** (UC-DEPLOY-01, UC-DEPLOY-02,
  UC-EDIT-02). Source pickers, validation, live-resolved previews
  all hinge on knowing what another project provides.
- **Edit-time validation** (UC-DEPLOY-01, UC-EDIT-02). Pain points
  surface when validation runs late. Pushing it to edit time
  eliminates whole classes of failure.
- **Action-from-anywhere** (UC-DAILY-01, UC-DIAGNOSE-01,
  UC-DEBUG-01). Frequent actions should not require navigation.
- **Visible state, not hidden state** (UC-DEPLOY-02, UC-EDIT-01,
  UC-DIAGNOSE-01). Pre-build flags, option values, last errors —
  visible by default at the right level of detail.

These are the things a fresh design session should keep in mind when
choosing surfaces and interactions.
