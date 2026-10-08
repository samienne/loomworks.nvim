# loomworks.nvim — Feature Backlog

Items deferred during development. Not prioritized — just collected so
they don't get lost.

---

## Stable channel: resolve by highest version, not `/releases/latest`

The stable update channel (lw self-update, `lw release query --channel
stable`, and through it the editor's `binary.channel = "stable"`) resolves via
GitHub's `/releases/latest`, which is the most recently *published* full
release, not the highest version. A hotfix backported to an older release line
and published after a newer stable release would become "latest", so the
channel would offer a downgrade (or skip the newer stable). Resolve stable by
listing releases and taking the highest non-prerelease version (spec 16.29
ordering), as the unstable channel already does since #166.

## `lw launch add` for build-target launches (LumeEditor request)

`lw launch add` can only create command launch configs. LumeEditor asked for
a target-kind form that creates a build-target launch (the executable of a
project target, like the editor's launch editor does), e.g. `lw launch add
<name> --target <project>:<target>`. Needs: the CLI surface, validation that
the target exists in the active profile's configuration, and the same
publish/intent defaults as the other CLI-created launch configs.

## Daemon step 5d: route `lw reset`

Decided 2026-10-05: `lw reset` shares build directories with build and clean,
so it moves into the workspace daemon after step 5c, using the confirmation
rule from spec/core/daemon.md section 19.15 (the client asks first and the
request carries the answer). A standalone `lw configure` command was
considered and not added: configuring stays a step of `lw build`
(`--reconfigure` forces it).

## Daemon follow-ups (after step 5e)

- `lw daemon stop` on a daemon that is already retiring still triggers the
  editor's relaunch (needs a stopping broadcast).
- The successor launched after a version retirement is often the version
  just retired: one wasted start per retirement.
- Daemon log lines include the client name/version unescaped (newline
  injection into the log).
- `lw trust --discard` from the CLI does not make the editor reload.
- Idea: show client-executed runs (the daemon only prepares `lw run`; its
  task ends before the program exits) in `lw status` and the status page.
- An attached selection whose runtime lock is held on another host still
  runs in-process with only the "could not take" line; decide whether it
  should wait and fail busy.
- No end-to-end test for an attached device run found by probing (the
  device stubs are in-process only).
- `ensure.meet` with `no_launch` is only tested through a mocked meet.
- Editor retirement after an editor stall: the unanswered-status bound is
  one `retire_check_ms` tick (30 s default,
  `lua/loomworks/daemon/observer.lua` ~883-929), so an editor event-loop
  stall of 30 s or more while a status is in flight ends the retire wait for
  that session (the daemon stays observed / editor runs in-process; nothing
  breaks). Changing it is a spec 19.16 change; consider measuring from the
  reply time or allowing one missed tick.

## Two meanings of "clean"

The editor's `C` action deletes the build directory and resets the unit to
unconfigured (spec section 4.7), while `lw clean` runs the build system's own
clean target. Decide whether to align the names or the behaviour.

## Daemon tasks in overseer and build messages

Decided 2026-10-05: in daemon observer mode, a CLI-started (remote) task shows
in fidget, lualine and the status page, with its output, but not in overseer's
task list, and its output is not parsed into the quickfix list or diagnostics
(spec/core/daemon.md §19.16). Design both together in the step where editor
operations themselves run in the daemon: then the editor's own builds leave
overseer too unless daemon tasks can appear there.

## Variable rename: what should it cascade to?

Found while fixing PR #75. Renaming a variable in the editor's variable editor
is implemented as delete-old + add-new. Deleting the old variable removes every
configuration's `variables.<old>` override, so those values are lost. The
compiler-family `overrides.<family>.<old>` entries are *not* touched: they stay
behind, pointing at a name that is no longer declared.

So a rename silently drops per-configuration values and leaves dangling family
overrides. Decide what a rename means (spec question, §1.3.1):
- **Cascade**: rename `variables.<old>` in every configuration and
  `overrides.<family>.<old>` in every family block along with the declaration
  (like `rename_project_configuration` does for configurations).
- **Refuse**: reject a rename while any override references the old name, and
  say which ones.

Either way, a plain delete should then also decide what happens to
`overrides.<family>.<name>` (remove, or refuse), so no path leaves an override
for an undeclared variable.

---

## `lw status` on narrow terminals

At 60–80 columns the project rows of `lw status` have room for only about one
configuration name: the description summary column takes up to 36 columns
(§16.35) before the configuration list gets what remains. PR #74 stops names
being cut mid-way, but does not win back any width.

Options (needs a §16.35 spec change):
- **A smaller summary cap on project rows** (or a cap that scales with the
  terminal width), so the configuration list keeps a usable share.
- **A continuation-line rule**: when the list does not fit, it wraps to an
  indented continuation line instead of being cut with `…`.

---

## Show unpublished changes in the CLI

Found in the v0.1.39-beta.3 field test of descriptions. After `lw publish`,
the tester changed a project's description locally, and neither `lw status`
nor `lw project list` showed that the item now differed from loomworks.json.

The editor shows this: its status page marks an item with `+` when its working
copy differs from the published baseline, plus a separate "removed upstream"
marker (spec §2.4, `spec/ui.md`). The CLI shows nothing, for any kind of
change, not just descriptions. `describe --json`'s `"source"` field is
unrelated: it says where the text comes from (workspace files vs. a module's
project-file default), not whether it is published.

Ideas:
- **The same `+`** on the rows of `lw status` and the list commands
  (`project`, `config`, `configset`, `profile`), driven by the existing
  predicates `Workspace:is_project_modified` / `is_config_modified` /
  `is_config_set_modified` / `is_profile_modified`, so the editor and the CLI
  agree by construction. Also a removed-upstream marker where it applies.
- **`"modified": true`** per item in `--json` output (`describe --json` today,
  and any future list `--json`).
- **Optional summary line** in `lw status`: "N items have unpublished changes -
  `lw publish`". This is a guard for agents and scripts that edit through the
  CLI and forget to publish.

It needs a small spec addition: §2.4 defines `+` for the editor only, and §16
has no publish-state marker. Low priority, because it only matters for
repositories that commit loomworks.json.

---

## Export / import follow-ups

Deferred from `lw export` / `lw import` (spec §16.39):

- **Editor commands** `:Loomworks export [file]` and `:Loomworks import
  <file>`, with the import summary and review shown in a confirm dialog. The
  CLI covers the use case. The editor picks up a CLI import through its file
  watcher.
- **Restoring an import backup** with a command (e.g. `lw import --restore
  <backup>`) instead of copying the file back by hand.
- **The serializer does not enforce §2.1's ban on absolute paths.** Option
  values, toolchain or machine files, path-typed variable defaults, launch
  working directories and module binary overrides reach loomworks.json (and an
  export) as written. A publish/export warning naming absolute paths (outside
  `${VAR}` expansions) would make this visible.
- **Byte identity of DEL and C1 characters.** Export writes DEL and C1 control
  characters as `\u` escapes and publish writes them raw. Making publish
  escape them as well would make the two byte-identical in every case.

---

## Extra source roots for a project

Reported by a user of a superproject setup (local repro repos:
`C:\src\LumeSdk` and `C:\src\LumeEditor`). LumeEditor's CMake
`add_subdirectory`s the whole SDK from a path OUTSIDE the workspace (cache PATH
variable `LUME_FRAMEWORK_SOURCE_DIRECTORY` → `C:\src\LumeSdk`), so the
LumeEditor build's compile_commands already contains every SDK translation
unit. But a file opened under `C:\src\LumeSdk` gets no project —
`project_for_buf` only matches files under the workspace root — so clangd
falls back to no/other compile flags, or a second clangd (rooted at the SDK)
starts.

Ideas:
- **Discover extra roots from the CMake file API**: codemodel `directories`
  whose `source` lies outside the workspace root are extra source roots of that
  project (generic hook: a module reports extra roots per configured unit).
- **Compile-db membership**: "which active project's compile database contains
  this file" as the fallback lookup for a buffer outside the root (the owned
  compile_commands stream already indexes files).
- **Explicit `source_roots`** on a project as a manual fallback.
- **Precedence**: the workspace of the current directory wins — a file that is
  both an extra root of this workspace and inside another loomworks workspace
  belongs to the cwd's workspace while it is active.

---

## Remote execution on devices — deferred pieces

Core §18 ([spec/core/remote-exec.md](spec/core/remote-exec.md)) v1 runs named
foreign executables (`lw run`, `lw test --target`) on a device through an SDK
provider's device runner. Deferred:

- ~~**PRIORITY — a hard kill of `lw` orphans the device program.** Found testing
  v0.1.34 on a Mate 60 Pro. Ctrl-C works (exit 130, the remote program is
  stopped), but CTRL_BREAK_EVENT or closing the console window ends `lw` with
  0xC000013A and no cleanup: the remote `sh -c … ./prog` and the program keep
  running on the device, and `<serial>.lock` is left behind (the next run
  reclaims the stale lock fine). Options, not exclusive: handle CTRL_BREAK and
  CTRL_CLOSE like Ctrl-C; tie the remote process lifetime to the transport
  session (the program dies when the hdc shell does); or have the next run on
  that device kill leftovers it tracked by the `__LW_PID_<n>=` pid line
  (persisted beside the lock).~~ DONE (#69, v0.1.39): Ctrl-Break / console
  close / hangup stop the program like Ctrl-C, and a later run reaps leftovers.
- **`lw device list` outside a workspace** fails with "no loomworks.json
  found". Listing devices needs only the SDK runners, not a workspace.
- **Staging "N removed" is opaque.** When the program changes, staging reports
  "N removed" without saying what; name the removed files, or say they are the
  previous program's per-run files.
- **Native executables in a harmony project** could run through the same ohos
  device runner (not needed yet).
- **ctest-registered tests on a device** — static listing via
  `ctest --show-only=json-v1` turned into exec requests (§18.6, cmake §15.3).
- **`cpp_compiler` device runners** — cross gcc/clang kits whose programs run on
  a networked board (cmake §15.1).
- **Device-farm lock interop** — `LOOMWORKS_DEVICE_LOCK_DIR` relocates the lock
  directory; lock-file format compatibility is validated with a concrete farm
  (§18.7). Prior art: the farm harness takes a farm-wide per-serial lock
  (`~/util_locks/<serial>.lock`) through its own library.
- **Generic device-log view (`device_log_format` hook)** — §18.13 "Later"; the
  ohos plugin's harmony.md §6.5 points here. Core's `device_log.lua` claims a
  module can supply its own parser and prefilter but hard-codes hilog
  (`parse_line`, `make_prefilter`, `match_filter`, level ranks, renderers), and
  `session_tracker.lua` calls `device_log.make_prefilter` itself. Meanwhile the
  plugin's `hilog.lua` already holds a copy for the runner's `receive` /
  `display`. The step:
  - **Moves to the plugin's `hilog.lua`:** `parse_line` + record shape;
    `LEVEL_RANK`, `HILOG_LEVELS`, `LEVEL_HL`, the level cycle
    (`off → I → W → E`) and `set_level` semantics; `proc_matches_bundle` +
    `make_prefilter`; the field half of `match_filter` (`pid`, `proc`, `tag`,
    `level`); `render_compact` / `render_verbose`; option validation and
    defaults.
  - **Stays in core** (a generic record view): the streaming task, singleton,
    `start` / `stop` / `toggle` / `show` / `hide`; `LogView` (ring buffer 5000,
    batched flush 250 ms / 200 per flush / 2000 pending cap, autoscroll, pause,
    clear, header, raw records, help window); the free-text pattern filter over
    the rendered line; `sanitize_line` (hilog.lua may reuse it).
  - **New seam** (spec change to core §11.2 when implemented): `start{}` takes
    a `format` table — `{ parse(line) → record|nil, prefilter(record) → bool,
    match(filter, record, rendered) → bool, render(record, layout) → string,
    highlight(record) → group|nil, filter_keys = { { lhs, desc,
    fn(filter) → filter } … }, default_filter }` — supplied by an optional
    module hook `device_log_format(tool_data, { pid, bundle, options })`. It
    replaces `device_log_options` and the direct `make_prefilter` call in
    `session_tracker`. `set_level` becomes a generic `update_filter(patch)`;
    harmony's `set_device_log_level` / `:LoomworksDeviceLogLevel` call it with
    `{ level = … }`.
  - **UX unchanged:** the view still owns the filter table and re-renders from
    the ring buffer on every change, asking the format only to judge and render.
    The level-cycle key (`cl`) and any tag/proc keys become hilog's
    `filter_keys`, so keymaps and the help window stay the same, and CLI and
    editor filter through the same `hilog.lua` functions.
- **Editor launch chain** for foreign targets (§18.11: build → deploy → stage →
  execute from the editor, output + device log views, stop = cancel). v1 is
  headless only; the editor refuses a foreign target via `foreign.check_local`.
- **Debugging and test-explorer integration** for foreign targets (§18.11).
- **stdin forwarding** to device programs (§18.5).
- **hiview faultlogger reports for lw-launched runs** — hiview doesn't write
  faultlogger/cppcrash-*.log for lw-launched runs (only
  faultlog/temp/cppcrash-<pid>-*.json, which lw collects). Manual runs with the
  same `./<exe>` name DID get a faultlogger report, so the exec name isn't the
  cause. Remaining differences: lw's `$$`+exec wrapper vs a plain
  `cd … && LD_LIBRARY_PATH=… ./exe … > out.txt 2>&1` in one hdc shell string,
  and stdout/stderr streamed over hdc vs redirected to a file on the device.
  Needs a controlled phone experiment varying one factor at a time. Low
  priority: the collected temp json has the full stack.

---

## Workspace trust

Follow-ups to workspace trust (spec §17, `lw help trust`), not done:

- Matching a detected `vcvarsall` against vswhere-reported installs (the path
  already comes from detection, never from the cache).
- CMake options that name programs (`CMAKE_<LANG>_COMPILER_LAUNCHER`,
  `CMAKE_MAKE_PROGRAM`, `CMAKE_PROJECT_INCLUDE`), `toolchain` / meson
  `machine_file` and shell project commands in loomworks.json are treated as the
  project's build description (explicit builds only, spec §17.8) — a stricter
  mode could gate them too.
- Deploy **sources** with an absolute `path` (a copy INTO the workspace) are not
  gated.
- A CI opt-in (`LW_TRUST=…`) was considered and not added: a fresh CI checkout
  has no `.nvim` state, and `lw trust --yes` covers a restored cache.
- Explicit `lw nuke` does not take build-directory locks (the cache it resets is
  untrusted, so its directories are unknown); it deletes `.nvim/build/` wholesale.
- **Tester/dev recipe vs `trust.key`.** With `LOOMWORKS_DATA_DIR` pointed at a
  separate dev data dir and no `trust.key` in the stable data dir, a fresh key
  is created in the dev dir, and existing workspaces then report
  ".nvim/loomworks.user.json is not signed by this machine". Document it in the
  recipe, or copy / hard-link the stable key into the dev dir when it exists.

Also noted during the hotfix: the loomtest runner (independent of loomworks)
spawns its test commands through overseer without `loomworks.exe` resolution
(the `ctest` it runs is still a bare name — safe on Neovim ≥ 0.12, whose
jobstart no longer searches the cwd); the Linux `nice`/`ionice` wrapper
passes bare names to execvp; and pinned-cache GC (`<data>/loomworks/pinned/`
grows per pinned version/hash).

---

## Standalone CLI — deferred pieces

The standalone command-line runner ([specification.md §16](spec/core/headless.md),
ARCHITECTURE.md "Standalone Runner & Distribution") ships a simple v1
(`build`, `test`, `profiles`). Deferred beyond v1:

- ~~**Headless third-party module loading.**~~ DONE — `lw module install |
  update | remove | list` acquires external module plugins from a curated,
  hash-pinned index (`modules.json`) into the per-user data dir, resolved
  alongside system Lua (spec §16.20; ARCHITECTURE.md "Module acquisition").
  The `harmony` entry is published: `samienne/loomworks-module-ohos.nvim`
  v0.1.0, installed from its GitHub codeload archive. Remaining thoughts:
  whether the editor grows an index-aware installer too, and provenance/signing
  for module artifacts beyond the index-pinned hash.
- ~~**Project-committed wrapper.**~~ DONE as `lw bootstrap` (`lw.sh` /
  `lw.cmd` / `lw.pin`, spec §16.21–16.24); polish follow-ups in "Bootstrap /
  pinned-launcher polish" below.
- **`lw build <profile> -- <target>` hint.** Args after `--` go verbatim to
  `cmake --build`, so a bare target name fails with cmake's "Unknown argument
  X" (`-- --target X` works). When an arg after `--` looks like a target name
  (matches a known target, no leading `-`), hint `--target X`.
- **`lw run` device targets.** Non-debug launch is DONE — `lw run <profile>
  [target]` builds then executes a launch target, and `lw launch` manages the
  configs (spec §16.17). Plain cross-built executables now run on a device
  headlessly (§18, #62); §11 package install/launch and DAP stay editor-only.
- ~~**Keyless signing / provenance.**~~ DONE (v0.1.2) — and not with minisign:
  the host verifies with **ECDSA P-256 + SHA-256** because luvi's bundled
  lua-openssl cannot do Ed25519's one-shot verify, and minisign isn't a
  dependency worth adding when the openssl CLI is already there. `SHA256SUMS`
  is signed with the release key and published as `SHA256SUMS.sig`, with the
  public key embedded in the README so the documented install commands never
  need editing per release (spec §16.15). GitHub artifact attestations ship
  too (`actions/attest-build-provenance`), so `gh attestation verify` works
  with no key material and an anchor outside this repo — the recommended CI
  path. CI verifies each signature against the committed public key right
  after signing, so a drifted secret fails the release rather than a user's
  `lw self-update`.
- ~~**Cross-process build-dir locking.**~~ DONE — `lua/loomworks/build_lock.lua`:
  a per-build-dir `O_EXCL` advisory lockfile with an mtime heartbeat (crash
  reclaim), shared by the editor (`Workspace:_acquire_file_lock`, refcounted,
  wired into overseer) and the CLI (`with_build_locks` around build/clean/test/
  run). Fail-fast; `lw unlock <profile>|--all` to force-clear. Spec §16.6.
- **Precise run-env scoping (Windows launch, §8.7).** Build-target launches
  currently prepend *every* shared-library output dir in the build tree to
  `PATH` (Windows only; matches `meson devenv` breadth). This can be narrowed
  to only the dirs the executable actually links. The data is available:
  meson `introspect --targets` → `target_sources[].parameters` lists the
  flattened link line as path-qualified `.lib` import libs, **including
  subproject libs** (freetype, tracy) — the `depends`/`dependencies` fields do
  NOT (empty / external-only). Dir of each `.lib` = its DLL dir. Est. ~1–2 h
  for clang-cl "link-line dirs" (enough for reactive); ~3–5 h for a robust
  DLL→DLL transitive walk + mingw/gcc `-L`/`-l` parsing. cmake would be
  separate (file-api dependency graph, cleaner). **Deferred on purpose:**
  precise scoping trades over-inclusion (narrow same-name-DLL ambiguity, already
  mitigated by Windows-gate + deterministic order + exe-dir-first) for
  *under*-inclusion (a runtime-only transitive DLL not on the link line → the
  binary fails to load it) — a worse, harder-to-debug failure mode. Only worth
  doing if the same-name case actually bites.
- **Side-by-side beta mode.** Let a tester run a downloaded pre-release `lw`
  from a scratch dir without touching the installed one: today a fresh release
  host shares the per-user data dir (bundles, settings, channel) with the
  installed lw, so its `self-update` installs into the same `lua-<ver>/` set
  (and replaces whichever host it is), and `install` targets the one install
  location. Wanted: a per-invocation data-dir override or a *portable mode*
  (e.g. a marker file / flag that keeps data beside the exe), plus a way to
  fetch and verify a bundle for this binary without installing it or replacing
  any host. `LOOMWORKS_DATA_DIR` covers part of it (data dir only; not config,
  not the install target, not discoverable). Found testing v0.1.33-beta.3.
- **Keep `<exe>.old` after `install` for rollback.** `lw install` (and the
  Windows host self-update swap) renames the replaced binary to `<exe>.old`,
  and the next start deletes it (`host_update.cleanup_old`). Consider keeping
  it after an `install` — e.g. until the next successful install/self-update,
  or behind `lw install --rollback` — so replacing a working lw with a broken
  pre-release is one step to undo.
- **A real host/bundle compatibility contract (spec-first, §16.14).** The
  v0.1.36 bundle broke every bundle-routed command on hosts older than v0.1.34
  (an unguarded top-level `require("boot.help")`; a user's CI on the v0.1.2 host
  + `lw self-update`). Hotfix `fix/old-host-compat`: every boot use in
  `lua/loomworks/**` degrades on an old host, a static guard
  (`tests/old_host_compat_spec.lua`, floor v0.1.2) and a CI job running the
  bundle under released hosts (`scripts/ci/old-host-compat.sh`, also a release
  gate). Still open: §16.14 says a bundle declares the minimum host it needs,
  but every release declares `min_host_version = 1` and `HOST_VERSION` has been
  1 in every tag, so the declaration protects nothing. Wanted: the bundle
  checks the host's release version or a host capability list at load time and
  degrades or refuses with "update the lw binary"; releases declare a correct
  `min_host`; and self-update keeps the host from installing a bundle it
  cannot run. Decide the capability model in the spec first (release version
  vs capability names), then retire the per-call guards where the contract
  covers them.
- **Tell the user when `lw migrate` would change something.** Found in the
  discoverability audit (fix/cli-discoverability, spec §16.38): `lw migrate`
  is reachable only from `lw help`. Nothing in `lw status` or `lw health`
  says the workspace files are in an older shape. Wanted: a passive health
  suggestion (and so the status `N suggestions` line) when `lw migrate --check`
  would report changes, at the cost of running the check on that path. Spec
  first: §16.19 (migration) and §16.31 (which providers are passive).
- **Count orphaned build directories in status / health.** Also from the
  discoverability audit. After `lw profile remove` (or a configuration
  rename) a build directory with cached state can belong to no profile any
  more. Only `lw reset --all` removes it, and nothing shows that it exists.
  Wanted: a count in `lw health` (and the status suggestions line), e.g.
  "2 build directories belong to no profile — lw reset --all". A per-orphan
  reset (`lw reset --orphaned`, which leaves live profiles alone) would make the
  remedy narrower than `--all`. Spec first: §16.30 and §16.31.

---

## Bootstrap / pinned-launcher polish (next release)

Found on the first real use of `lw bootstrap` (samienne/reactive#165, pin
0.1.35). All items below were implemented on `feature/bootstrap-polish` (spec
§16.7, §16.12, §16.21-16.24, §16.31 provider #4, §16.32):

- ~~Repo hygiene written by `lw bootstrap`: `.gitattributes` eol rules,
  `.nvim/cache/` appended even when `.nvim/` is ignored, `lw.sh` not 100755
  when bootstrapped on Windows.~~
- ~~`lw health` checks the bootstrap files (user request).~~
- ~~Launchers: no download retry; garbled curl progress meter in `lw.cmd`;
  bare `lw.cmd` vs `.\lw.cmd`, which pin runs.~~
- ~~Source-built `lw` can't bootstrap or update (test key embedded); bumping
  the pin from a source build (`./lw.sh update`).~~
- ~~`lw update` output ("refreshed" when nothing changed; no old -> new; no
  "signature verified").~~
- ~~Help: `lw help ci` old flow; which launcher under Git Bash; `lw help
  update` on a bare release binary.~~
- ~~Old pinned binaries in `.nvim/cache` never pruned.~~
- ~~`--version` output non-ASCII (mojibake).~~

The v0.1.36-beta.1 field test (reactive re-pinned 0.1.35 -> 0.1.36-beta.1)
added fixes shipped in beta.2 on the same branch: appends to
`.gitattributes` / `.gitignore` keep the file's line endings (a CRLF working
copy under `core.autocrlf=true` got LF lines, "w/mixed"); no duplicate
attributes header; no trailing space in `lw.cmd` messages; flat report wording
(no nested parentheses, one "already at" message, per-file generation labels);
`lw version` names the pin instead of the channel in pinned context; `lw
health` prints ASCII.

Open follow-ups:

- **Redundant `.nvim/cache/` line.** A repo bootstrapped before the
  "committed rule already covers it" check can carry a `.nvim/cache/` line
  that a broader `.nvim/` rule makes redundant. Neither bootstrap/update nor
  the launcher checks (`lw bootstrap` / `lw health`) notice it or offer its removal.
- **Pin path printed three ways.** The fetch line and `lw version` show the
  pin as `/c/...` (MSYS, from `lw.sh` under Git Bash), `C:\...` (from
  `lw.cmd`) and `C:/...` (from the host). One normalized form would read
  better; the launcher can only print what its shell gives it.
- **Cached binaries pruned only by `lw bootstrap install`.** Old `lw-<ver>-<asset>`
  binaries in `.nvim/cache/` are removed by `lw bootstrap install` / `upgrade` only;
  a checkout that switches branches between pins (or a launcher-only user who
  never runs update) keeps accumulating them. Health reports them; the
  launcher could prune on a fresh fetch.
- **Launcher "written by" label mixes a beta range with a stable pin.**
  `lw bootstrap install` reports old launchers as "written by lw
  0.1.36-beta.1-0.1.37-beta.1" (the range of versions with byte-identical
  launcher content, from `boot/launcher.lua` GENERATIONS) even when
  `lw.pin` is stable 0.1.36, so a stable pin looks like it sits beside beta
  launchers. Prefer the stable version name in the range, and say plainly
  when the launchers match the pin's own generation. (Reported by the
  reactive repo during its 0.1.36 -> 0.1.43 repin.)
- The per-user pinned cache (`<data>/loomworks/pinned/`) is still never GC'd
  (see the note under Workspace trust). The standalone suite runs in
CI on Linux only, so the dynamic `lw.cmd` tests (retry, PATH shadowing) run only
when the suite is run on Windows locally - a Windows standalone CI job would
cover them.


### Bootstrap command restructure (feature/bootstrap-commands)

`lw bootstrap` = read-only status page (shared checks with `lw health`),
`lw bootstrap install` = one converge command, `--pin-only`, `upgrade` alias,
`lw update` deprecated (spec §16.24). Fixed along the way: plain `lw bootstrap`
re-pinned a pinned repo to the running host's version; `lw update` ignored the
update channel; `./lw.sh update` provisioned the pinned bundle first (so a pin
with a bad bundle hash could not be repaired through the launcher); two
implementations of the committed-ignore rule. Follow-ups:

- ~~**Remove `lw update`** one release after the deprecation (help topic,
  parser branch, README row, tests).~~ DONE (#89): removed after 0.1.42; `lw
  update` is now an unknown command (exit 2) whose one line names `lw bootstrap
  upgrade` and `lw self-update`.
- ~~**Launcher template comment** still says "Regenerate with `lw update`".~~
  Done in 0.1.37-beta.2 with the launcher self-identification generation
  (`LOOMWORKS_LAUNCHER`).
- **J. Repair needs the network.** A plain repair `install` re-fetches the
  signed SHA256SUMS on every run, so it fails offline even when the pin is
  unchanged. Idea: skip the fetch when the pin is kept and every required hash
  is present (nothing to download), verifying only when the pin moves.
- **K. Old hosts and plain `bootstrap`.** An old `lw.cmd` / global `lw` (0.1.36
  and earlier) treats plain `lw bootstrap` as the old write and can fail with
  "no version to pin" (seen through a 0.1.36-pinned `.\lw.cmd`). Only the docs
  can mitigate that for old hosts (README "Changed in 0.1.37").
- **Pin-only is inferred** (pin + neither launcher). Deleting both launchers
  by hand therefore reads as pin-only; a recorded mode was considered and
  declined.
- **0.1.37-beta.2 field-test leftovers** (reactive, minor):
  1. After `upgrade` moved `lw.pin`, the follow-up `install` that refreshed
     the launchers hinted `git add lw.sh lw.cmd` and left out the equally
     uncommitted `lw.pin`: the install commit hint should list every
     uncommitted launcher/pin/metadata file, not only those this run wrote.
  2. Prerelease version ranges read badly with a hyphen
     ("lw 0.1.36-beta.1-0.1.37-beta.1"); use "0.1.36-beta.1 to 0.1.37-beta.1".
  3. In a fresh repo the combined "not committed yet" finding is joined by the
     overlapping ".gitattributes rules not committed" and ".gitignore rule
     uncommitted" findings, each with its own partial `git add`; fold them
     into the combined one.
  4. The personal-rule message is generic; `git check-ignore -v` names the
     exact source (e.g. `c:/Users/…/.gitignore:10`), so show it.
  5. The `tools` hint still prints `lw profile create …` when run via
     `./lw.sh` (invoked form not applied there).
  6. "line endings ok" is reported for untracked files whose index form
     cannot be checked yet; say "not checked until committed".
  7. `lw update` (now `lw bootstrap upgrade`) on a prerelease pin prints two near-duplicate lines
     ("newer than the newest stable … - kept", then "already at … - no
     changes"); print one.
  8. Run as the plain exe right after writing launchers, the tail points at
     `lw bootstrap`; `./lw.sh bootstrap` is the better pointer then.

## Flaky tests

- ~~`tests/meson_spec.lua:229` ("configure command uses meson setup with
  --buildtype") calls the real `builder()`, which `mkdir -p`s a fixed
  `/root/.nvim/build/App\Debug` — on Windows CI this intermittently fails with
  E739 "file already exists". Use a temp root / stub the mkdir.~~ DONE (#77,
  #81).
- ~~`tests/cli_worktree_add_spec.lua` "a main with no working config is
  'nothing to pull'" failed once in a full local run ("not in a git
  repository") and passes alone; likely cwd/env leakage from another spec.~~
  DONE (#80): the cause was a slow git probe read as "git missing".
- `tests/daemon_readonly_cli_spec.lua:260` ("lw status over the projection
  shows the daemon's running task") shows "running tasks: unavailable
  (timeout)" under parallel load / on the Windows CI runner; passes alone.
  Seen on PR #168 CI and a local `make test`. Make the wait robust.
- `tests/daemon_reset_cli_spec.lua` "every case: the same output..." failed
  once on Windows CI (PR #171 run 37734890114, docs-only change), passed on
  rerun.

### `lw health fix <n>` (deferred, user idea)

`lw health` numbers the issues that have an automatic fix; `lw health fix <n>`
(or `--all`) applies fix n from the **last** health report, read from the
cached report, so the numbers stay stable until health runs again. Before
applying, re-verify that the issue is still present. Each fix runs exactly the
command health printed; there is no second repair path. Show the command and
ask for confirmation unless `--yes`. Only loomworks-owned, safe repairs
(launcher/pin repair, cache prune, tool rescan): never commits, never deletes
outside `.nvim/`, never touches trust. The printed-command remedies stay as they
are until then.

Open questions:

- Outside a workspace, health deliberately caches nothing (user decision), so
  the last report needs a per-user location.
- Meanwhile, `lw health --json` should expose an `id` and a `fix_command` per
  issue.

---

## Module-signalled build staleness

Today loomworks tracks *configure* staleness (options snapshot vs live config)
but not *build* staleness (did a source change since the last build?). The
build tool (ninja/meson) is the authority, so build tasks always run — a fast
incremental no-op, but still a spawned step. `lw test` was made cheaper by
letting a runner declare `run_command_all_rebuilds` so its build is skipped
(§16.16), but the general build path still always runs.

Idea from sami: let a **module signal build staleness** — a module could
report a unit as "always stale to build" (cmake) or compute real staleness
(compare source mtimes / a stamp file against the last build). The generic
build/test path would then skip the build step when the module reports "up to
date", instead of relying on the build tool's own no-op. Needs more thought:
where the staleness signal lives (Module vs ConfigUnit), how it interacts with
the cache, and whether reimplementing "is a rebuild needed?" is worth it when
ninja already answers that in milliseconds.

---

## LSP auto-restart on crash (integration-declared)

Generalize the clangd-specific restart loop that sami had in their personal
config into an opt-in field on LSP integrations. Motivation: on very large
codebases clangd routinely gets OOM-killed — the user wants it re-launched
automatically, with `--j=<n>` halving on each SIGKILL so it settles into a
memory budget the system can actually support.

Proposed shape on integrations:

```lua
M.auto_restart = {
    on_signals = { 9, 11 },         -- SIGKILL, SIGSEGV
    on_sigkill_adapt_cmd = function(cmd, attempt_state)
        -- mutate cmd (halve --j=N) and return the new cmd + updated state
    end,
}
```

`lsp.lua` would wire `on_exit` generically, call the integration's
`on_sigkill_adapt_cmd` when present, and re-install via `vim.lsp.config` +
`vim.lsp.enable`. Default for clangd: halve `--j=` on SIGKILL, reset to 12
on SIGSEGV.

Also consider an upper-bound restart count and a backoff so a truly-broken
config doesn't hot-loop forever.

User-facing: users can set `auto_restart = false` on a server to opt out;
leaving it unset gets the integration's default behavior.

---

## MSVC toolchain support for the meson module

Meson builds fine with MSVC (`cl.exe`) on the ninja backend, but only
when invoked under an environment where `vcvarsall.bat` has run — that
sets `INCLUDE`, `LIB`, `PATH`, etc. for the target architecture. The
meson module's compiler detector (`lua/loomworks/cpp_compilers.lua`)
currently only finds gcc/clang on PATH; `cmake_kits.lua` already has
the MSVC + vcvarsall plumbing for cmake.

To add MSVC-meson kits:

- Extend `compilers.detect` (or a sibling `msvc_kits`-style helper) to
  enumerate VS installations via `vswhere.exe`, the same way
  `detect_msvc_kits` in `cmake_kits.lua` does.
- When the picked tool carries a `vcvarsall` field, the meson module's
  `tasks()` needs to wrap the configure / compile commands so they
  run under the vcvarsall env. Easiest shape: generate a `cmd.exe /c
  "call vcvarsall.bat arch && meson setup ..."` wrapper, the way
  cmake currently does. The wrapper shape should live next to the
  meson task builders, not inside `compose_task_env`, because it
  changes the *command* shape, not just the environment.
- `MesonTestUnit` should prepend MSVC redist DLL locations (the
  per-arch directories under the installation's `VC/Redist/...`)
  rather than a plain `compiler_bin_dir` — MSVC compilers don't ship
  runtime DLLs next to `cl.exe`.

Scope note: this is the reason `cmake` can pick "Ninja + MSVC" today
but `meson` can't. Tracked separately from the gcc/clang support that
already landed.

---

## ~~Strict separation of auto-generated vs user configurations~~

**Addressed** (feature/config-prefix-namespacing + diagnostics work).
Auto-gens are prefix-namespaced (`variant:Debug`, `auto:default-default`),
filtered out of all serialization paths, regenerated every load from
the module. User configs are unprefixed; `:` is banned in user names.
Source-missing stubs are tracked (`_source_missing = true`), preserved
across remerges for graph soundness, GC'd by `update_mapping` when the
last referrer is removed. Stale references surface via `:is_valid()`
on Configuration / ConfigurationSet, aggregated into the status page
Diagnostics section + winbar indicator.

Deferred ergonomics not implemented (revisit if friction shows up):
- `[orphan base]` rebase action — currently a manual edit of `inherits:`
- `Override this config…` shortcut on auto-gen rows
- Self-healing migration that drops user.json entries identical to the
  auto-gen (to collapse pre-prefix bloat)

Supersedes the narrower "[stale] badge for source-missing configurations".

---

## ~~One route to a variant: inherit it, don't declare it~~

A user configuration can become concrete two ways: declare
`variant: Release` on itself, or inherit a base that provides one
(`inherits: variant:Release`). Both are supported today —
`Configuration:is_abstract()` only asks whether a variant exists, by either
route, and the meson/cmake modules propagate from a base only when the
config doesn't declare its own.

**DONE for authoring** (2026-07-20). The CLI no longer offers `variant` as a
settable field: `lw config add <project> <name> [base]` takes a base to
inherit, and `set … variant` refuses with a pointer to the base providing it.
Derived values are no longer persisted either — a module still propagates a
base's variant onto the config for the build path, but marks it (`_derived`),
and serialization skips it, so an inherits-only config stays inherits-only in
both user.json and loomworks.json (spec §1.4).

**Reading a declared `variant` is still supported**, deliberately: existing
files keep resolving, including `c:/src/reactive/loomworks.json`, which
declares `variant` on all four of its configurations. Still open if the
stricter line is ever wanted:

- A migration rewriting `variant: X` → `inherits: variant:X` where a matching
  auto-gen exists, so old files converge on the single route.
- Rejecting a declared `variant` at load time (breaking; needs the migration
  first).
- A decision about modules whose variants aren't enumerable up front — those
  have no `variant:*` base to inherit, so the inherit-only rule needs an
  answer there before it can be made universal.

Related and DONE: an abstract configuration is no longer buildable — a
profile mapping one reports itself unbuildable instead of letting the module
pick a default build type (spec §1.4).

## Plugin-based loomtest adapter discovery

Mirror the existing plugin-based module registry idea: loomtest should
auto-discover test adapters by scanning a conventional directory
(`lua/loomtest/adapters/<name>.lua` on the Neovim runtimepath). Each
file self-registers with `loomtest.register_adapter(...)`. Third-party
plugins can ship new adapters without editing loomtest itself.

Under this pattern, `lua/loomworks/loomtest_adapter.lua` would move to
something like `lua/loomtest/adapters/loomworks.lua` or stay in the
loomworks tree and just follow the same self-registration contract.
Keymaps for `<leader>t*` move out of loomworks entirely — loomtest
ships its own default keymaps.

Prerequisite for eventually splitting loomtest into its own repo
cleanly.

## Pluggable debug adapter architecture

`lua/loomworks/debug.lua` currently hardcodes behavior for nvim-dap and
has static tables of known adapters per language (`DEFAULT_ADAPTERS`,
`KNOWN_ADAPTERS`, `JS_ADAPTERS`). To let new adapters plug in without
editing core — and to give orchestration-heavy adapters (remote
debug-server bridges, on-device protocol bridges) a clean home —
mirror the LSP registry pattern.

### Registry shape

```
lua/loomworks/debug.lua               — dispatcher + registry
lua/loomworks/integrations/debug/codelldb.lua
lua/loomworks/integrations/debug/cppdbg.lua
lua/loomworks/integrations/debug/pwa_node.lua
lua/loomworks/integrations/debug/<vendor>.lua       (third-party)
```

Each integration self-registers:

```lua
require("loomworks.debug").register("codelldb", M)
```

and exposes:

- `M.languages = { "c++" }` — what language keys resolve to this adapter
- `M.build_config(spec, workspace) -> dap_config` — shape the DAP
  config (current `JS_ADAPTERS` transform for pwa-node lives here)
- `M.setup(spec, callbacks) -> teardown_fn|nil` — optional pre-launch
  orchestration (push a debug-server, set up port forwarding, etc.);
  returns a teardown closure invoked on session end
- `M.attach_pid_transform(spec, pid)` — optional, for multi-adapter
  attach to a PID discovered from the primary session
- `M.default_enable = true|false` — whether core auto-picks this
  adapter for its language(s) when user hasn't overridden

### Dispatcher changes

- `M.run(spec, callbacks)` finds the integration by adapter name,
  runs its `setup`, merges the returned config into `dap.run`, and
  registers the teardown on `event_terminated` / `event_exited`.
- `M.resolve_adapter(workspace, language)` reads from the registry
  (iterate integrations whose `languages` contain the key, pick by
  user override then `default_enable`) instead of hardcoded
  `DEFAULT_ADAPTERS`.
- `M.known_adapters(language)` / `M.known_languages()` become
  registry queries. Status page (`ui/sections/debug.lua`) follows.

### Forcing function

The first device-native debug adapter (shipped in a separate plugin)
will be the natural second adapter that validates the design. Land
this refactor first as a pure-internal branch (no behavior change;
existing codelldb/cppdbg/pwa-node tests still pass), then build the
device adapter on top.

### Out of scope here

- Third-party plugin discovery (scanning rtp for integration files) —
  follows the LSP pattern but can wait. First pass: hardcoded
  `require()` list of built-in integrations, same as the original LSP
  refactor's first cut.

## Streaming device scan into picker

Currently `Workspace:scan_devices()` waits for all modules' `list_devices`
callbacks to complete before opening the picker. On slow systems, the
underlying connector tool can take a couple of seconds, leaving the
user staring at "scanning for devices..." before the picker appears.

Ideally the picker would open immediately with results streaming in. This
requires a dynamic-source picker — not supported by `vim.ui.select`.
Options to investigate:
- Use Snacks.picker directly with `source = fun(cb)` or a dynamic items
  mechanism (Snacks is already a hard dependency)
- Cache previous scan results and show them immediately while re-scanning
  in the background, updating the visible list when new results arrive
- Start scans on workspace load so results are cached before the user
  opens the picker

Same treatment would benefit kit/SDK pickers and any other async source.

---

## Disable navigation keymaps in loomworks UI windows

`<C-o>`, `-` (oil.nvim), and similar global keymaps can navigate away
from loomworks status page, config editors, and other UI windows.
Fixed in loomtest explorer — need same treatment in loomworks View/Tree
widget (view.lua, status.lua).

---

## No-tool profile: MSVC auto-detection metadata

When creating a profile without selecting a tool (no cmake kits detected),
cmake picks MSVC automatically. The resulting build is multi-config but
loomworks metadata (cmake_info.multi_config, tool_data.generator) doesn't
reflect this. Investigate why tool detection didn't offer MSVC and why
cmake_info is wrong after configure.

---

## Overseer template references as launch targets

LaunchTarget currently supports module targets (cmake executables) and
command-type configs (loomworks.json launch section). Could also support
referencing overseer task templates (e.g., from VS Code launch.json)
as launch targets.

## Configuration conflict detection

Detect when two configurations share the same output directory (e.g.,
TypeScript outDir). Warn via confirmation dialog before building a
conflicting configuration. Auto-detect from outDir comparison; optionally
allow explicit conflict declaration in loomworks.json.

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

## ~~Post-build file copy support~~

**Addressed** (feature/deploy-steps). Implemented as deploy steps on launch
configurations — declarative copy steps that ensure build artifacts are
deployed before launch, with freshness tracking. See specification.md
section 9.8.

## TypeScript LSP integration (tsconfig switching)

Similar to clangd integration for cmake: provide factory functions that
route ts_ls/vtsls to the correct tsconfig per profile. Would need a
`typescript.tsconfig` field per configuration in loomworks.json, and a
`ts_ls_root_dir` factory similar to `clangd_root_dir`. Auto-restart
ts_ls on profile switch when tsconfig changes.

Low priority — most TypeScript projects use a single tsconfig.json.
Only needed when profiles map to different tsconfig files (e.g.,
tsconfig.debug.json vs tsconfig.release.json).

## Tool selection when adding second keyed-module type

When adding a project of a *new* keyed-module type (e.g., meson to a
cmake workspace), existing profiles need a tool selection for the new
module type. The multi-tool data model (profile.tools dict) supports
this, but the UI flow for selecting tools per module type during
add-project is not yet implemented. Currently only single-keyed-module
workspaces are fully handled (tool inherited from existing profiles).

## Clear active profile on deletion

When a profile is deleted, the active_profile in loomworks.user.json
should be cleared if it matches the deleted profile. Currently the
profile is removed from cache but user.json still references it,
leaving a dangling active_profile until the user activates something
else.

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

## Decouple config_key from variant name

Currently `config_key` is derived from `variant + tool_key` (e.g.,
`"Debug:ninja-gcc-12"`). This makes the variant name load-bearing for
identity — renaming a configuration requires rekeying cache entries,
registry slots, and profile configuration arrays.

Ideally, `config_key` would be a stable opaque ID assigned at creation
(e.g., sequential or UUID). The variant name would be purely a display
label. Rename would then be a simple field update with no rekeying.

This would also align with the architectural principle that keys should
not be used for runtime lookups — only direct object references.

## Modules as domain objects + cache deserialization isolation

Modules are currently stateless function tables loaded via `require`.
Making them domain objects would:

1. **Module domain objects** — Workspace owns Module instances. Each
   module owns its Tool registry. `project._module` replaces
   `project.type` string. `tool._module` replaces `tool.mod_type`
   string. Module-specific logic (cmake task generation, info parsing)
   lives on the module object; generic behavior stays in shared code.

2. **Deserialization layer** — The `_sync_*` methods become the only
   place that does key→object resolution. They resolve every string
   reference from cache/config into domain object references, then
   pass fully-resolved data to `_update()`. After deserialization,
   key→object tables are not accessible to domain objects.

3. **No key lookups in domain objects** — `_update()` receives
   pre-resolved references. `_workspace` back-reference either goes
   away or becomes a narrow interface (no registry access). Domain
   objects navigate only via direct references.

This eliminates the remaining string-based lookups: `find_tool(mod_type,
tool_key)`, `mod_type` strings throughout the codebase, and
`_workspace._projects[key]` during `_update()`. Cache format stays
the same (strings on disk, resolved on load). Object identity
preservation and remerge ordering are unchanged.

Entry point: Module domain objects (wrapping existing function tables).

## Built-in sanitizer/tool configuration templates

Provide pre-built abstract mixin configurations for common development
tools: address sanitizer (asan), thread sanitizer (tsan), undefined
behavior sanitizer (ubsan), memory sanitizer (msan). Users inherit from
these mixins to create concrete configs (e.g., `Debug-asan` inherits
`[Debug, asan]`).

Best starting point is the Meson module — Meson has first-class sanitizer
support via `-Db_sanitize=address` etc., so the mapping is clean. For
cmake, sanitizer flags are compiler-specific (`-fsanitize=` for gcc/clang,
`/fsanitize=` for MSVC) and would need compiler detection to generate
correct options. Defer cmake sanitizer templates until compiler-aware
option generation is available.

## Profile/variable persistence lost after task failure

Observed: after creating a profile or adding variables and triggering a
configure/launch that fails, the data may disappear from user.json or
loomworks.json on a subsequent save. Possibly related to the stuck
operation / remerge interaction, or a save triggered by the failure
path overwriting with stale data. Error logging added to `_save_user`
(2026-04-02) to help diagnose if it recurs.

## Variable/deploy discoverability and documentation in UI

The variable system and deploy steps lack in-editor documentation.
Users need help text or descriptions for:
- Available built-in variables (${workspace_root}, ${build_dir}, etc.)
  and what they expand to
- The difference between ${variant} (cmake variant) and ${configuration}
  (config name from profile mapping)
- Source path is relative to build dir (for path type)
- ${project_path} is relative, use ${workspace_root}/${project_path}
  for absolute
- Variable type meanings (string vs path — path enables segment editor)
Could add tooltips, help text in editors, or a help dialog.

---

## ~~Rename-back shows entry in both profiles and orphaned sections~~

**Fixed** (fix/rename-orphan-accumulation). Root cause: rename used
`_rebuild_profile_projects_for` which destroyed and recreated domain
objects. Fix: pure in-place mutation — Configuration, Profile, ConfigUnit
all keep identity. Old BuildDir orphaned as domain object; rename-back
adopts it. Introduced BuildDir domain object, removed `_last_raw_cache`.

---

## Graceful degradation for external dependencies

Current hard dependencies: **overseer** (build/launch), **snacks** (picker,
explorer window). Soft: fidget (progress), nvim-dap (debug), lualine
(status component).

Issues to address:
- **fidget**: build/deploy progress uses fidget exclusively — if not
  installed, progress is silent. Should fall back to `vim.notify` or
  a minimal echo.
- **snacks**: used for `vim.ui.select`-style pickers and the loomtest
  explorer window (`Snacks.win`). Should fall back to `vim.ui.select` /
  `vim.ui.input` for pickers. Explorer window needs snacks or an
  alternative (floating window API directly).
- **overseer**: core dependency, hard to remove. Document as required.
- Audit all `require()` calls to external modules for pcall guards.

---

## codelldb: no local variables for dynamically loaded .node modules

**Symptom**: When debugging a Node.js native addon (.node shared library)
via codelldb (either launching node directly or attaching), breakpoints
and line stepping work but local variables are not shown in scopes.

**Root cause**: LLDB's PDB plugin crashes when trying to resolve symbol
addresses for dynamically loaded modules. `target symbols add` loads
the PDB but hits assertion failure: `obj_load_address != LLDB_INVALID_ADDRESS`
in `SymbolFilePDB::InitializeObject`. LLDB can't determine the load
address of the .node module in memory.

**Findings**:
- PDB files are present and well-formed (function symbols + line tables load)
- `image dump symfile` shows empty Types/Compile units before process runs
- Build uses clang `-g -Xclang -gcodeview` producing CodeView/PDB format
- Standalone cmake executables debug fine with full locals
- Issue is specific to shared libraries (.node/.dll) loaded at runtime
- cppvsdbg (Microsoft's native debugger) would handle this but is
  licensed for VS Code only

**Potential fixes**:
- Switch to DWARF debug info (`-gdwarf` instead of `-gcodeview`) — LLDB
  handles DWARF better for shared libraries
- Wait for LLDB PDB plugin improvements (active development area)
- Structured debug entry with symbol search paths (future loomworks feature)

---

## Plugin-based module registry

Currently modules are hardcoded in `modules/init.lua`. Third-party plugins
should be able to register modules by placing files in `lua/loomworks/modules/`
on the runtimepath. Auto-discovery would scan all rtp entries, validate the
module interface (`M.id`, `M.detect`, `M.info`, `M.tasks`), and register
valid modules alongside built-ins. Needs: interface validation, error handling
for broken modules, load order guarantees, potential config for disabling
specific modules.

---

## Profile-level SDK integration (design ready, not implemented)

**Problem**: Currently profiles select tools per module type independently.
Cross-compilation requires all modules to use the same SDK. Two projects
of different module types in the same profile should be able to share a
single SDK selection.

**Design decisions**:

1. **SDK is a profile-level selection**, not per-module. Profile has:
   - Configuration set
   - SDK (optional domain object reference, nil = host build)
   - Tool overrides (for modules SDK doesn't cover)

2. **SDK provides tools to all modules it supports**. Core asks
   `sdk:query(module.id)` for each module — no module/SDK-specific logic
   in core. If SDK returns nil for a module, that module uses host tools.

3. **No fallback guessing**. If no tool mapping exists for a module in a
   profile, the profile is flagged "incomplete" rather than silently
   creating a default. No automatic Visual Studio / default compiler
   fallbacks. User must explicitly select.

4. **Profile name includes SDK**. "Debug:<sdk>" or "Debug:ninja-clang-18".
   SDK profiles are distinct from host profiles.

5. **Profile creation flow**: pick config set → pick "Host" or an SDK →
   if host, pick cmake kit (existing flow). If SDK, tools derived
   automatically from SDK capabilities.

6. **Serialization**: profile stores `sdk_key` string. Deserialization
   resolves to SDK domain object via workspace. If SDK not found,
   profile is incomplete.

7. **Core stays generic**: no `if sdk_type == "<vendor>"` anywhere. Core
   iterates modules × SDKs via query interface.

**Implementation needed**:
- Profile domain object: add `_sdk` reference field
- Profile creation UI: SDK picker step
- Tool resolution: SDK-first, then module detection, then incomplete
- Remove all tool fallback guessing from modules
- Serialization: sdk_key in user.json profiles section
- Status page: show SDK on profile, incomplete state

---

## LSP UI: cmake-specific compile_commands hint

Deferred from the incomplete-profile-policy work. Same rationale as
above — UI v1 still mostly drives the experience.

`lua/loomworks/ui/sections/lsp.lua:44`:

```lua
elseif entry.project_type == "cmake" then
    tree:leaf("compile_commands_dir: (not found)", "DiagnosticWarn")
end
```

Hardcodes a "compile_commands_dir not found" warning specifically for
cmake projects. The right shape is for the module's `lsp_configs`
emission to carry an opaque hint flag (e.g.
`expected_compile_commands = true`) and the UI to render that
flag generically. Other modules that ship clangd configs (meson, and
third-party C/C++ modules) are already in the same position; the
pattern just isn't formalised yet.


## Headless CLI: skip an already-done, unchanged configure

`lw build` / `lw test` / `lw run` re-run the module `configure` step on every
invocation. The staleness model (`ConfigUnit:is_stale`, BuildDir option/module
snapshots) is designed for the single-process editor, where the snapshot stays
frozen in memory between a configure and a later config edit. In the headless
CLI each invocation is a fresh process that must reconstruct staleness from the
cache, and wiring `record_task_result` into the headless build path produced
incorrect state (recorded `failed_build` on success) and did NOT detect a
`lw config set` option change — so skipping configure would silently miss
config changes. Reverted to always-configure for correctness. A proper fix needs
the load path to reliably populate `_cached_options` / `_cached_module_config`
from the cache and freeze them across processes. The re-configure is a fast
near-no-op (`cmake` reconfigure / `meson setup --reconfigure`).

---

## Multi-config preset with no CMAKE_BUILD_TYPE builds silently

For a multi-config preset (Ninja Multi-Config / Visual Studio / Xcode) that
declares no `cacheVariables.CMAKE_BUILD_TYPE`, `cmake.multi_config_variant`
returns nil and the build step omits `--config` — cmake then builds the
generator's default configuration (typically Debug). This is correct-but-silent:
the user gets a Debug build from a preset that never said Debug, with no signal.
A small improvement would be a user-facing warning at build time (or in
`M.validate`) telling the user to add a build type to the preset or pick one,
rather than silently defaulting. Deferred — the current behavior does not crash
or corrupt anything; it just isn't self-explaining. (Single-config presets are
unaffected: their build type is mined into `variant`.)

---

## Compiler-trait refactor for backend-specific behavior

Lift the family-dependent cache decisions — the cache-tool preference (sccache
vs ccache) and the MSVC-style debug-info / `/Z7` handling — off coarse
compiler-family enum checks and onto explicit capability **traits** on the Tool
domain object (e.g. `msvc_style`, `debug_info_model`, `preferred_cache_order`).

Motivated by the clang-cl bug in the compiler-cache feature, where
`active_compiler_family()` over-normalized clang-cl → `clang` and collapsed a
behaviorally-significant distinction (clang-cl is msvc-style). The fix threaded a
dedicated `cpp_compilers.is_msvc_style` signal, but that is a point patch: a
trait/capability model makes backend-specific behavior capability-driven and
extensible — a new compiler declares its traits and the cache logic works with no
new `if family == X` branches — and keeps family-sniffing from metastasizing
across modules/core. Polish, not urgent.

## Comprehensive `lw health` environment inventory

Make `lw health` a full "is this machine ready?" check (like `:checkhealth`).
Outside a workspace: detect everything loomworks knows about — build systems
(cmake + version, meson, ninja, make), compilers (gcc/clang/MSVC via
vswhere/clang-cl), compiler caches, LSP servers (clangd, qmlls), debug adapters
detectable headlessly (mason dir / PATH), installed module/SDK plugins, lw
host/bundle/channel/update — and report found (with versions) vs missing.
Inside a workspace: same inventory, but grouped **Required by this workspace**
(derived from the projects' module types + the active profile's tools — nothing
new to declare) vs **Other**; only a missing *required* item is actionable and
counts toward `lw status`'s "N suggestions".

Design: a generic optional hook per module/SDK/integration (e.g.
`health_inventory(ctx)` → items with found/missing, version, required-by) so
core only aggregates and renders (no module-specific logic in core). Runs only
on explicit `lw health` (vswhere / `--version` probes are slow), fits the
two-tier health cache (§16.31). `:checkhealth loomworks` can later render the
same data. Spec: §16.31 + a module-interface hook. Planned as its own feature
branch after v0.1.29 stable.

**Implemented** on `feature/health-inventory` (`inventory.lua`, module / companion
/ SDK contributors, `lw health --verbose/--json`): core §16.33 (inventory,
declarations/probes, required split, inventory cache tier keyed on the
environment, `--json`), §8.4 `health_inventory` / `health_requirements`, §9.3 /
§10.1 / §8.9.6 hooks (integration declarations in host-neutral inventory
companions), per-module/integration/SDK declarations, README.

Deferred from v1 (follow-ups):
- `:checkhealth loomworks` / an editor-native rendering of the same results;
- minimum-version checks (a too-old tool reads as found);
- a `lw health --check` mode that exits non-zero on a missing required item
  (CI can test the `--json` output meanwhile);
- a per-user (cross-workspace) inventory cache;
- Qt-install discovery for qmlls (only PATH + Mason today).

Follow-ups from tester feedback on v0.1.31-beta.1 (not done yet):
- Mason qmlls shows no version (its receipt source id is `qmlls-workflow@0.7`,
  not a qmlls version) and its path is the `mason/bin` `.cmd` shim rather than
  the real binary it launches;
- executable tools (`exe_declaration`: cmake, ninja, make, node, …) report only
  the FIRST search-path hit — a second ninja further down PATH is not listed —
  unlike compilers and language servers, which list every location;
- the `lw` row has no path (the running binary's location is not shown);
- JSON `id`s embed lower-cased absolute paths (`cxx:c:/…`, `msvc:c:/…`), so
  ids are not portable across machines — CI diffs between hosts see them change;
- inventory items carry only a free-text `hint`; no structured remedy (e.g. a
  command + a doc pointer) a script or UI could act on;
- SDKs appear only when a profile pins them or the provider's `detect_all`
  finds them (by design) — say so in `lw help health` / README ("unpinned SDK
  installs are not probed") so an empty SDKs line isn't read as "no SDK
  installed".

Follow-ups from tester feedback on v0.1.31-beta.2 (next release):
- **Kits require ninja on the plain PATH.** `cmake_kits` offers Ninja + MSVC /
  clang-cl kits only when `ninja` is on the plain PATH, although those builds
  run inside vcvars, which appends VS's bundled ninja (health already accepts
  the bundled one for a required ninja). A machine whose only ninja is the
  VS-bundled one gets no Ninja + MSVC kits.
- **No way to pick a newer standalone clang-cl.** A standalone LLVM clang-cl on
  PATH (e.g. 22.1) is paired only with the newest VS install, and only when
  that install has no bundled clang-cl of its own; when the newest VS bundles
  one (e.g. 19.1), the standalone never becomes a kit. Offer it as its own kit
  (paired with the newest VS's toolset/vcvars).
- **Attribution layout varies by context** (cosmetic): a single requirer reads
  `profile/project`, several read `N profiles (…)`; make the two shapes line
  up.

## Compiler cache for Visual Studio generator builds

CMake's `CMAKE_<LANG>_COMPILER_LAUNCHER` is honored only by the Ninja and
Makefile generators, so loomworks' compiler cache is **not applied** under the
Visual Studio (and Xcode) generators — cmake.md §5d documents this as a non-goal
and the profile row reads `Cache: not applied (<generator> generator)`.
Caching an MSBuild build needs a different mechanism. sccache's documented
recipe (unverified against the current sccache docs — re-check before building
on it) goes through `CMAKE_VS_GLOBALS`:

- `CLToolExe` / `CLToolPath` pointing at a copy of `sccache.exe` renamed to
  `cl.exe` (sccache acts as the compiler when invoked under that name),
- `UseMultiToolTask=true` (so MSBuild still parallelises per file),
- `DebugInformationFormat=OldStyle` (i.e. `/Z7`; `/Zi` makes sccache fail the
  compile — the same PDB problem as §5d),
- `TrackFileAccess=false` (MSBuild's file tracker does not follow the wrapper).

It is more fragile than the Ninja launcher (a copied/renamed binary to manage,
MSBuild property plumbing, no per-target opt-out) and would need its own
staleness record, `cache_launcher_applicable` answer and compatibility scan.
Motivation: LumeEditor measured a hand-made `cl.exe` shim of this kind at
12.2 → 4.3 min for its Visual Studio generator build.

## ~~Scriptable active-profile selection (`lw profile select <name>`)~~

**DONE** (v0.1.30, fix/v0.1.30-cli): `lw profile select <profile>` works without
a terminal (same resolution as `lw build <profile>`; re-selecting the active
profile is `(unchanged)`, no write) and `lw profile select --none` clears the
active profile. Only the bare picker needs a TTY (headless §16.9).

Tester feedback (v0.1.29 beta, non-interactive CLI). `lw profile select` is
interactive-only (a picker on a terminal), and there is no way to CLEAR the
active profile from the CLI; `lw profile create … --activate` is the only
scriptable way to set it. A script / agent that needs the editor's active
profile to follow what it builds (or to reset it to "none", so status and
health evaluate every profile) has to edit `loomworks.user.json` by hand.
Wanted: `lw profile select <name>` (non-interactive when a name is given,
same resolution as `lw build <profile>`) and `lw profile select --none` (or
`lw profile deselect`) to clear it. Mind the agent guidance (`lw help agent`:
never change the user's active profile unasked) — the command is for the user's
own scripts, not something lw does implicitly.

## ~~`lw status` lists presets whose `condition` excludes this host~~

**DONE** (v0.1.30): the cmake module evaluates preset `condition`s (all CMake
types, inherited from bases, three-valued — unknown macros never hide) and
leaves out presets false on this host (spec/modules/cmake.md §3). A set that
still maps one gets the usual missing-configuration diagnostic.


Tester feedback (v0.1.29 beta, Windows). `lw status` (and the configuration
lists) show a project's macOS-only CMake presets on Windows: loomworks reads
`CMakePresets.json` but ignores each preset's `condition` (e.g.
`{"type": "equals", "lhs": "${hostSystemName}", "rhs": "Darwin"}`), so presets
CMake itself would refuse on this host appear as buildable configurations.
Evaluate the preset `condition` (equals / notEquals / inList / notInList /
matches / notMatches / anyOf / allOf / not, with `${hostSystemName}` and the
other macros CMake allows there) against the host, and hide — or mark
"not for this host" — the presets it excludes. Decide whether an excluded
preset already mapped in a configuration set should be a diagnostic rather
than silently vanish.

## Compiler-cache / config follow-ups from real-project testing (next patch)

Tester feedback (LumeEditor, lw 0.1.29-beta.8, Windows/MSVC). Ordered by
severity.

- ~~**MEDIUM — /Zi scan findings go stale when CMake re-configures itself.**~~
  **DONE** (fix/zi-scan-staleness): the record carries the module's stamp of the
  scanned data (core §8 `cache_compat_stamp`); builds and health re-scan when it
  changed, and the passive health key includes it. The
  cache-compatibility scan (§5.1, §8 `cache_compat_scan`) only runs after an
  `lw configure`; when ninja re-runs CMake on its own (after a CMakeLists /
  `.cmake` edit) the recorded finding is not refreshed, and `lw health` shows
  the recorded result despite `lw help health` saying it "always refreshes the
  local checks". Observed both ways: after switching `/Zi` → `/Z7`, health still
  says "sccache will fail N compiles"; after re-adding `/Zi`, health reports
  nothing and a failed build gets no closing hint. Fix: health and the
  failed-build closing line re-scan (compile commands / file-api reply) when
  that data is newer than the recorded snapshot (the reply mtime is already the
  freshness signal for the owned compile_commands); at minimum document
  `lw build --reconfigure` as the way to refresh the scan.
- ~~**LOW — `env.PATH` and `env.Path` can both be set.**~~ DONE (v0.1.30):
  env names are one entry per name ignoring case on every host; setting a
  case variant replaces the existing entry and says so. Two entries appear in
  `lw config show`; with case-insensitive environment layering on Windows one
  silently wins. Replace the existing case-variant on set (Windows), or warn.
- ~~**LOW — `lw profile set … cache sccache` when already `sccache`**~~ DONE
  (v0.1.30): prints `(unchanged)`, no write. Was: prints "set"
  and rewrites user.json; `lw config set` reports "(unchanged)" and does not
  write. Make profile set match.
- ~~**LOW — `lw profile set … cache bogus` is accepted**~~ DONE (v0.1.30):
  validated at every set path (profile set, config set variables.cache /
  overrides.<family>.cache); a hand-edited invalid value is a diagnostic.
  Was: accepted, then shows
  "bogus (not found)" and silently builds uncached. Validate the policy value
  (`auto` / `off` / a known launcher name) at set time.
- ~~**COSMETIC — user.json key order changes on rewrite**~~ DONE (v0.1.30):
  `io.write_json` sorts object keys at every depth (all three files). Was:
  key order changed on rewrite, producing noisy diffs.
  Serialize with a stable (e.g. sorted, or original-order-preserving) key order.
- ~~**WORDING**~~ DONE (v0.1.30) — all six items below: "every target, nearly
  every unit"; "which sccache will fail"; health qualifies "using sccache — but
  it will fail N compiles"; the PATH warning names the full param; sub-command
  `--help` prints its own section; help cites no spec sections.
  - "nearly every target (… 77 of 77 targets)": only the *unit* count is
    "nearly"; say "every target" when all targets are affected.
  - The failed-build closing line says "which sccache cannot cache", underselling
    it — the scan says the compiles will FAIL; align the severity wording.
  - Health shows "Compiler cache: using sccache" directly above "sccache will
    fail N compiles" — reads as contradictory; qualify the affirmation (or
    suppress it) when a failing finding exists for the same configuration.
  - The PATH warning for `overrides.msvc.env.path` names it `env.path`; name the
    full key the user set.
  - `lw profile query --help` and `lw config unset --help` print the whole
    parent command's help; show the subcommand's section.
  - User-facing help still cites spec sections (§16.9 build, §16.16 test, §1.3.1
    config); help text should not reference the spec.
