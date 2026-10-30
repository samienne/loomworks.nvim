# Changelog

What changed in each release of loomworks (the `lw` runner and the Neovim
plugin). `lw release-notes` shows these notes offline, from the release you
run; `lw self-update` shows what changed since your previous version.

<!--
How to write an entry (spec section 16.37; tests/release_notes_spec.lua checks it):

* Every change adds its items under `## Unreleased`, in the section that fits.
* Sections, each at most once per entry, in this order:
  Breaking, Upgrade notes, Added, Changed, Fixed, Security, Removed.
  Breaking and Upgrade notes are what a user must act on; lw shows them even in
  its shortest summaries.
* An item is one `- ` bullet (continuation lines indented by two spaces) that
  says what changed for the user, ending with the PR number: `(#79)`.
* ASCII only; Markdown only for `code spans`.
* Cutting a full release: rename `## Unreleased` to `## <version> - <YYYY-MM-DD>`,
  add a one- or two-sentence summary paragraph under the heading, and put an
  empty `## Unreleased` back on top. The release workflow refuses a full-release
  tag without its entry. Pre-releases have no entry of their own: they ship
  the Unreleased entry.
* Entries 0.1.29 to 0.1.39 were reconstructed from the git history after the
  fact.
-->

## Unreleased

### Breaking
- In the editor's default `daemon` mode the Lua getters return plain tables
  copied from the workspace daemon's views, each with its `id`, instead of
  Profile, Project and ConfigurationSet objects: `get_profiles`,
  `get_active_profile`, `get_projects`, `project_for_buf`, `get_config_sets`,
  `get_active_configuration_set`, `get_tool_entries`, `get_tools_by_type`,
  `get_orphaned_configs` and `get_lsp_options`. They return nil while the
  editor has no view from the daemon, and `get_workspace()` always returns
  nil. Code that calls methods on these objects must use the records' fields,
  or keep `runtime = { mode = "in-process" }` until that mode is removed.
  `lw.compile_command_for_file()` and `:LoomworksCompileCommand` are not
  available in `daemon` mode. (#336)
- A configuration set's `mappings` in the workspace view (`view.Workspace/1`)
  and in `ConfigSets/1.add` / `update` is now a list of `{ project,
  configuration }` references (in the view also `missing`, which replaces the
  set's separate `missing` object) instead of a project key to configuration
  name object. (#345)

### Upgrade notes
- The editor now uses the workspace daemon by default: builds, configures,
  cleans, launch preparations and tests run there. An operation the daemon
  cannot take (not connected yet, no `lw` found, an older daemon) or declines
  is refused with the reason in one notification line, the same note the
  status page's `Runtime:` line shows; it no longer runs in the editor
  instead. The editor ignores `LOOMWORKS_RUNTIME`, `LOOMWORKS_NO_DAEMON`, `CI`
  and `lw`'s `runtime-mode` setting. `setup({ runtime = { mode = "in-process" } })`
  keeps the old in-process editor for now; it is deprecated and will be
  removed. A disconnected editor also refuses device-target launches, and
  the status page's Debug Adapters section shows `unavailable` with the
  reason when the daemon does not offer the adapter mapping. (#258)
- A build-directory or device lock whose holder is still running but has
  stopped heartbeating ("hung") is no longer taken over after about 20 s: the
  command stops and names the recovery command, `--break-locks`. Scripts that
  relied on waiting out such a lock must pass `--break-locks`. `lw unlock
  <profile>` no longer removes the lock of a running holder; add `--force`. (#99)
- Scripts or CI that run `lw update` must switch to `lw bootstrap upgrade`
  (move a repository's pin) or `lw self-update` (update lw itself); `lw update`
  now fails with exit code 2. (#89)
- An unknown command (`lw frobnicate`) now exits 2, not 1, like every other
  usage error; scripts that test for exit code 1 must accept 2. `lw --check`
  (and any other option in place of a command) is an unknown option: use
  `lw status --check`. (#90)

### Added
- Experimental daemon: `Launch/1.targets` lists a profile's launchable
  targets (launch configurations, executable build targets and device
  targets, each with its project's id, the default marked), which projects
  still need a configure for the list to be complete, and whether a default
  is stored. `Profiles/1.set_default_target` stores one of them as the
  profile's default target in `loomworks.user.json`, or clears the stored
  choice when no target is given. The workspace view's project rows carry
  their parsed build targets (`targets`). (#340)
- Experimental daemon: `Maintenance/1.nuke` is the editor's nuke as a task:
  it lists what it removes and confirms with a plan token, refuses while a
  build-directory or workspace lock is held (naming the holder) or while any
  task of the daemon runs (listing them), and reloads the workspace after
  the removal. It is also served while the workspace load is refused (an
  invalid build cache, whose remedy it is), and once the removal started a
  cancel is ignored: the nuke runs to its end. (#315)
- Experimental daemon: `Maintenance/1.execute_deletion` deletes a profile, a
  configuration unit, an orphaned or stray build directory, every orphan or
  a project with its build state as a task, after a confirmation with a plan
  token, ending `DELETE OK: <label>`; a unit is named by its id or
  `{ project, configuration }`, an orphaned build directory by its id or
  `{ key }`; `view.Workspace/1` lists each orphaned configuration's `id`. (#314)
- Experimental daemon: `Sdks/1` on `/toolchains` -- `detect` lists the SDK
  providers and the installation paths each finds in the client's
  environment, `add` declares an SDK (an absolute path; a relative one is
  refused) and detects the toolchains again so its kits are offered, `remove` drops a declaration and detects again so its
  kits are gone -- and `Toolchains/1.rescan` detects every toolchain again,
  as the status page's `L` does. A detection that outruns the 45 s wait
  replies ok with a warning; `changed` follows when it finishes. Adding or
  removing an SDK in the status page now also detects the toolchains again.
  (#313)
- Experimental daemon: `Profiles/1.tool_choices` also lists the resolved
  SDKs relevant to the set, as `{ sdk = true, key, label }`, and
  `Profiles/1.create` takes one as `tool = { sdk = <key> }`, as the status
  page's tool picker does. An SDK not offered is refused. (#311)
- `lw launch set` takes `--description <para>` (repeatable), like
  `lw launch add`; it replaces the whole description, and
  `--description ""` clears it. `--working-dir ""` clears the working
  directory (#290).

- `lw` highlights its own lines: step headers (`==> [build] ...`), configure
  reasons, `BUILD OK` / `TESTS OK` and the other outcomes, failures and
  warnings, so a build's phases stand out from the tool output. New global
  options `--color=auto|always|never` and `--no-color`; `auto` checks standard
  output and standard error separately, and an empty `NO_COLOR` no longer turns
  color off. Build tool and program output is never touched; a repository
  pinned to an older `lw` gets the options dropped, not passed on (#270).
- `-v` / `--verbose` on `lw build`, `lw run`, `lw test` and `lw clean` prints
  every command a step runs under its header: configure, build, clean and test
  commands with their directory and environment overrides, the build
  directories a clean removes, deploy copies, and on a device run every device
  command. On a run or a test it covers the dependency build too. The
  environment line shows only what a step adds: a variable equal to the
  inherited one is left out, and one that extends it shows the added part with
  the inherited part as `$NAME` (e.g. `PATH=C:\gcc\bin;$PATH`). Before the
  command, `lw -v` is still the version (#273).
- `lw build`, `lw test` and `lw clean` run through the workspace daemon now
  highlight their lines the same way as in-process, following `--color` /
  `--no-color` (#277).
- `lw clean -v`, `lw test -v` and `lw run -v` also run through the workspace
  daemon now, with the same lines as in-process; their environment line is
  computed against the environment of the shell you ran `lw` from, not the
  daemon's (#278).
- `lw status` lists the repository's linked git worktrees in a short `Worktrees`
  section (path, branch, main and current markers, whether loomworks is set up
  there), capped like the other sections with a pointer to `lw worktree`. It is
  left out when there are no linked worktrees or git does not answer. (#255)
- `lw test --no-build` runs the tests against what is already built: nothing
  is configured, built or deployed (meson runs `meson test --no-rebuild`). An
  unconfigured project or an unbuilt test executable fails the run before
  any test starts, listing each one; a build that may be stale
  (configuration changed, last build failed) gets a note. Works with
  `--saved`, `--discovered` and `--target`. (#233)
- Experimental daemon: in daemon mode the loomtest explorer shows the tests
  the workspace daemon discovered (its tree, each unit's state and the last
  results, kept across reconnects); discovery runs in the daemon as a task
  the editor owns, when the tree is stale and on refresh. While the daemon
  is unavailable or the workspace unloaded the explorer header says so and
  refresh and runs are refused; nothing is discovered in Neovim. The neotest
  adapter is not available in daemon mode (one notice). In-process mode is
  unchanged. (#251)
- Experimental daemon: in daemon mode running and debugging tests from the
  loomtest explorer goes through the workspace daemon. A run (a test, suite,
  target, file or all) is one task the editor owns, with its build, shown as
  one overseer entry whose stop cancels it; the explorer, gutter signs and
  inline marks follow its per-case progress (another editor's runs too).
  Debugging a test builds it in the daemon and starts the debugger with the
  adapter the daemon resolved; its results are recorded when the session
  ends. A test's output, its first-error jump and the inline error detail
  are read from the daemon when shown. (#254)
- Experimental daemon: in daemon mode the status page's Diagnostics,
  Suggestions, Profiles, Orphaned, Configuration Sets, Projects and SDKs
  sections show the workspace daemon's view of the workspace, with build
  progress from the daemon's tasks; while the daemon does not offer it each
  of them shows `unavailable` with the reason, and nothing of them is
  computed in Neovim. The "loomworks.json not on disk" banner no longer shows
  before the daemon has loaded the workspace. Edits of projects and SDKs and
  the deletions made from the status page still write the files from Neovim
  and then refresh the view. (#286)
- Experimental daemon: in daemon mode the status page's publish (`:w`),
  revert (`:e!`), publish or revert of one item, intent (`P`) and
  description (`e`) edits, profile activation, creation and toolchain edits,
  and configuration set creation, edits and removal are calls to the
  workspace daemon that name the row's item by its id. One the daemon cannot
  take, or refuses (for example a row made stale by a reload), is an error
  notification and changes nothing; it is never done in Neovim instead. The
  status page is marked modified (`:e` refused) while the daemon's working
  copy has unpublished changes; a plain `:e` never reverts there, only
  `:e!` does. `U` (discard the working copy) shows what it
  deletes and refuses when the file changed since. Creating a profile from an
  automatic configuration set now adds the set together with the profile,
  not when the set is picked, in both runtime modes. (#317)
- Experimental daemon: in daemon mode the status page's project add (from
  the project browser), removal of a configuration or launch configuration,
  variable edits and removal, and edits of a project's fields (build dir,
  commands, environment, ...) are calls to the workspace daemon that name the
  project, configuration or launch configuration by its id; the variable
  editor reads the project from the daemon. A refusal is an error
  notification and changes nothing; it is never done in Neovim instead. The
  configuration, launch and deploy editors still write from Neovim. (#318)
- Experimental daemon: in daemon mode the status page's SDK section and `L`
  (detect the toolchains again) are calls to the workspace daemon: "Add SDK"
  lists the installations the daemon detects (with their versions and the
  provider's own prompt for a typed path), adds the one picked or typed (a
  typed relative path is taken from Neovim's working directory), and `D`
  removes the SDK by its id. A refusal is an error notification and changes
  nothing; it is never done in Neovim instead. `L` reports a detection that
  did not finish in time. (#324)
- Experimental daemon: in daemon mode the editor's builds, configures and
  module cleans (of a profile, of one configuration, a target's build and
  the clean of a rebuild) run in the workspace daemon as tasks the editor
  owns, instead of in Neovim. Each shows one progress entry (a profile build
  is one entry, not one per project), Cancel stops it through the daemon, a
  clean first stops the editor's own build on the same units, and closing
  Neovim cancels what it started. An explicit profile configure there
  configures every project, also configured ones. When the daemon cannot
  carry an operation (not connected, an older daemon) it runs in Neovim as
  before, its progress title saying "(in-process)". In-process mode is
  unchanged. (#195)
- Experimental daemon: in daemon mode the workspace daemon's tasks are listed
  in overseer. A build the editor started there is one overseer task (a
  profile build is one entry whose output has a `==> [build] <project>`
  section per project; in-process it is one entry per project); stopping it
  in overseer cancels it in the daemon, restarting it runs it there again. A
  build started by `lw` or another editor is listed read-only as
  `[lw] build <profile>`: stop and restart say where to cancel it. The status
  page's `Open overseer` works on these rows. When overseer cannot list them
  they stay on the status page only, with a note on the Runtime line. (#197)
- Experimental daemon: the workspace daemon can prepare a debug launch
  (`Launch/1.prepare_debug`: build, deploy and resolve the program exactly as
  `lw run` would, plus the debug languages and their adapters) and serves
  the debug-adapter mapping (`DebugConfig/1`: read it, set or reset a
  language's adapter in the working copy). Both preparations can also build
  only what an editor launch builds (the launch's dependencies and its own
  unit) instead of the whole profile. The editor starts using them in a
  later step. (#194)
- Experimental daemon: in daemon mode the editor's launches and debug
  launches of non-device targets are prepared in the workspace daemon (it
  builds the launch's dependencies and its own unit and runs the deploy
  steps, as one task the editor owns); the program itself still starts in
  Neovim, in overseer or nvim-dap, as before. A debug launch whose adapter is
  not installed stops with the install hint before anything is built.
  Restarting a launch's preparation task in overseer does not start the
  program: start the launch again instead. The Debug Adapters section reads
  and changes the adapters through the daemon. When the daemon cannot carry
  a launch (not connected, an older daemon) it runs in Neovim as before, its
  progress title saying "(in-process)"; device targets always do.
  Stopping while the daemon prepares a launch cancels it and no program
  starts; a second launch meanwhile asks before replacing it. The adapter
  check uses the daemon's adapter mapping, so a change made in the Debug
  Adapters section applies to the next debug launch at once. A target found
  to run only on a device after the daemon built it continues with the
  deploy in Neovim, as an in-process launch does. An error starting the
  prepared program is reported instead of leaving its progress spinning.
  In-process mode is unchanged. (#201)
- In daemon runtime mode the language servers are configured only from the
  workspace daemon: a configure, reset or profile switch run in the daemon
  (from the CLI too) starts, withholds or restarts clangd in Neovim without
  reopening the buffer, only the daemon writes the compile database
  loomworks owns, and the status page's LSP options are written only
  through the daemon (a failed write is an error; nothing is saved
  locally). While Neovim waits for the daemon (connecting, or the daemon
  has not loaded the workspace) buffers stay held; when the daemon cannot
  give the configuration (no `lw` binary, an older daemon, its load failed)
  they are withheld (lualine `(no lsp config)`), with the reason on the
  status page's Runtime line; a language server already running keeps
  running meanwhile. Losing the connection, or the daemon reporting the
  workspace unloaded, unloads it in Neovim until the daemon reports it
  loaded again: run/debug launches are not offered and are refused, the
  statusline shows no project, and on a lost connection its language
  servers stop and their buffers wait. An editor attaching to the daemon
  makes it load the workspace, so an editor-only session no longer stays
  unloaded. In-process mode is unchanged. (#205)
- `lw.buf_project(bufnr)` returns the buffer's project as a record (`key`,
  `label`, `type`, `path`, `abs_path` and the active configuration, tool key
  and state). It matches on a separator boundary, so a project at `/a/foo`
  does not claim a buffer in `/a/foobar`; `lw.project_for_buf` is unchanged.
  (#188)
- Experimental daemon: `lw daemon status` shows the daemon's idle timeout and
  when it will exit if no client connects (`idle  timeout 45s, exits at
  14:03:12 (in 45s) unless a client connects`), or that the idle timer is not
  running while other clients, an operation or background work keep it up.
  An older daemon shows no idle line. (#184)
- Experimental daemon mode: `setup({ binary = { channel = "stable" } })` (or
  `"unstable"`) lets the plugin's own `lw` move ahead of its pinned release.
  At most once a day and on `:LoomworksDaemon connect`, the pinned `lw` asks
  the channel for its newest release (`lw release query`, signed and
  hash-verified); a newer release this plugin can use (common protocol, same
  file formats, the root interface) is downloaded, checked against the
  release's hash and used from the next daemon launch on - a running daemon is
  not switched. The option is off by default; it never goes below the pin,
  moving from unstable to stable keeps an installed newer pre-release, and
  only the plugin's own `lw` follows it (never an `lw` on PATH, `binary.path`,
  `LOOMWORKS_LW` or `binary.source`). An unusable release, no network, or a
  pinned `lw` too old to ask is one note on the Runtime line and the current
  binary stays; `:checkhealth loomworks` shows the last check. (#169)
- Experimental daemon mode: the editor retires a running workspace daemon it
  cannot use - no common protocol, older file formats, or no root interface -
  when that daemon is idle and the `lw` the editor selected is known to be
  compatible and of another version. It asks the daemon to retire (never
  stops it), starts its own `lw` once the old daemon has exited, and says so
  in one notice and on the Runtime line. A busy daemon is left alone and
  checked again about every 30 s; a daemon whose only problem is older file
  formats stays observed meanwhile, and for the session when the editor does
  not retire it; a daemon with newer file formats, a compatible daemon of any
  version, and one of the same version are never retired; a refused or
  unanswered retire request is noted and starts nothing; a daemon that stops
  answering while the editor waits for it to become idle is noted and left
  alone; and a daemon of a given version is retired at most once per
  workspace per Neovim session, so a repository pin that keeps launching the
  same release cannot cause a loop (the note then suggests updating the pin
  or the plugin, or says that retiring that version failed earlier). (#168)
- Experimental daemon mode: before starting the daemon from an `lw` on `PATH`,
  `LOOMWORKS_LW` or `binary.path`, the editor checks it with `lw version
  --json` in the background (bounded to about 3 s, cached per binary for the
  session). An incompatible `lw` on `PATH` (no common protocol, newer file
  formats, no root interface) is skipped with a note and the plugin's own
  `lw` is used; an explicitly named one is only noted, never replaced. An
  `lw` that gives no answer is used and the connection decides; a missing
  feature interface only degrades that feature. `:checkhealth loomworks`
  shows the cached verdict. (#162)
- `lw release query [--channel stable|unstable] [--json]` names the newest
  release on an update channel without downloading or installing it: its
  version, whether it is a prerelease and, with `--json`, the SHA-256 of each
  host binary and the release's descriptor, all checked against the signed
  `SHA256SUMS`. It never runs a repository's pinned `lw` and writes nothing;
  the editor uses it to look for a newer compatible `lw`. (#161)
- Experimental daemon mode: the editor can download its own `lw` into
  Neovim's data directory when it has none (from the official release, or a
  mirror set with `binary.release_url` or `LOOMWORKS_RELEASE_URL`), checks the
  file against the SHA-256 the plugin carries, starts the daemon from it and
  removes older copies no editor has used for 14 days. A stuck download is
  restarted by `:LoomworksDaemon connect`; a damaged copy is never started
  and is downloaded again. The status page and `:checkhealth
  loomworks` show the download; a failure is one note and the editor stays
  in-process. `binary = { download = false }` turns this off. (#157)
- The plugin now pins an `lw` release: in daemon mode, an editor with no
  `lw` on `PATH` (and no `LOOMWORKS_LW` or `binary.path`) downloads the pinned
  release's binary for Linux x86_64, macOS arm64 or Windows x86_64 and starts
  the daemon from it. Releases are now built into a draft first and published
  only once the plugin is pinned to exactly those binaries and the release
  offers the interfaces the editor needs. (#159)
- `lw version --json` prints what the binary implements: its release, the
  daemon transport range, the working-copy and cache schema versions and every
  interface a daemon of it serves, with versions and schema digests. Each
  release publishes the same document as `lw-<version>-descriptor.json`,
  listed in its signed `SHA256SUMS`. Plain `lw version` is unchanged. (#155)
- `LOOMWORKS_INSTALL_DIR=<absolute path>` moves what lw downloads and installs
  (releases, pinned releases) to another folder, for an lw another program
  runs; settings, the machine key, modules and the daemons' sockets, identity
  and logs stay in the data directory. lw only ever lists, runs or removes the
  `lua-<version>` release folders it installed there, so the folder may be
  shared with other files. A pinned release older than this one ignores the
  setting and keeps its own copy of the pinned release in the data
  directory. (#155)
- Experimental daemon (`runtime-mode daemon`): the daemon protocol is now
  version 11 and describes itself. A client can ask the daemon which objects
  and interfaces it offers, at which versions, fetch each interface's schema,
  and subscribe to an interface's signals; the schemas live in
  `spec/protocol/` and ship inside the release bundle. Every request the
  daemon already served works exactly as before, and the daemon still serves
  clients of protocol 10. The editor now watches any daemon whose protocol
  range overlaps its own instead of requiring an equal number. A daemon started by an earlier `lw` is restarted
  when idle, or retired when busy, the first time the new `lw` talks to it.
  (#151)
- Experimental daemon: the workspace daemon offers its first interfaces
  beyond discovery: the workspace header and a change notification, the
  running tasks (list them, follow them starting and ending, and cancel one
  the client started; cancelling another client's task is refused), and a
  same-version snapshot of the model. `lw daemon run --stdio` serves the
  daemon protocol on standard input and output, and a conformance runner
  (`scripts/conformance.lua`) replays the golden transcripts in
  `spec/protocol/transcripts/` against any daemon binary over it. (#152)
- Experimental daemon: build, clean, reset, the batch test run, the
  preparation of `lw run`, the toolchain list and the compiler-cache query
  are offered as versioned interfaces, and the command line uses them when
  the daemon supports them (older editors and clients keep the earlier
  requests). A client is told when the workspace header changes (loaded,
  failed, another active profile). Entity, task and subscription ids on the
  wire are opaque strings tied to the daemon session, so an id kept from an
  earlier session is refused instead of naming another entity; this also
  changes the ids in the earlier snapshot reply from integers to strings
  (deliberate: nothing reads them yet), while older clients keep integer
  task ids. A daemon operation that failed after it may have started is
  never run a second time without the daemon: the command fails instead. A
  test run reports each test step's name, exit code and status. (#152)
- Experimental daemon (`runtime-mode daemon`): the workspace daemon answers
  two read-only requests, a snapshot of its loaded model (from which a client
  builds a read-only copy of the workspace) and host-probing queries (first:
  the detected toolchains) run in the requesting client's environment; its
  welcome now names the workspace, its active profile and a failed load. The
  read-only commands (`lw status`, `lw profile show` / `query`, `describe`,
  `project` / `config` / `configset` / `launch` list and show, `config get`,
  `lw tools`) read that copy in daemon mode when a daemon of the same `lw`
  version is already running, with the same output as before; they never
  launch, stop or restart a daemon, and read in-process otherwise (also with
  `--no-daemon` or CI, or when the daemon does not answer in time, with a
  one-line note). The daemon protocol version is
  now 10: a daemon started by an earlier `lw` is restarted when idle, or
  retired when busy, the first time the new `lw` talks to it. (#150)
- `lw status` shows each profile's build state in parentheses after its
  name: `(built)`, `(configured)`, `(unconfigured)`, `(unknown)`, or counts
  when its projects differ (`(1 built, 1 unconfigured)`), the same label as
  the editor's status page, colored as in the editor on a terminal. A task the
  workspace daemon is running shows its profile as running (`(1 building)`).
  So a script or agent can tell that a `lw build` or `lw clean` took effect.
  The profile rows no longer repeat the configuration set (`set=<name>`): a
  profile's name already starts with it. The editor's status page now also
  labels a profile whose units are all `unknown` (after an interrupted clean)
  as `unknown` instead of an empty label. (#141)
- Experimental daemon (`runtime-mode daemon`): `lw reset [<profile> | --all]`
  now runs in the workspace daemon, with the same listing, question, output
  and exit code, after one dim line `lw: resetting through the workspace
  daemon (pid N)`. The daemon never asks: `lw` shows its listing and asks you,
  and if the build directories to remove changed before you answered, the
  reset is refused (`run lw reset again`) instead of removing a directory you
  were not shown. If the daemon stops while you answer, the reset runs
  in-process with your answer. Ctrl-C stops the removal between entries. The
  editor and `lw status` show a running reset as `deleting` (`--all` on every
  profile it touches). The daemon protocol is now version 9: an older daemon
  is restarted when idle. (#143)
- `lw reset` (in-process and through the daemon) checks its plan again once it
  holds the build-directory locks: a build directory that another `lw build`
  created between the listing and the locks makes it refuse (`run lw reset
  again`) instead of removing a directory you were not shown. A build
  directory outside the workspace is no longer listed as one to remove (it
  never was removed, and the reset then failed): the listing names it as not
  removed and only its cached state is cleared. (#143)
- Experimental daemon (`runtime-mode daemon`): `lw clean [<profile>]` now runs
  in the workspace daemon like `lw build`, with the same output and exit code,
  after one dim line `lw: cleaning through the workspace daemon (pid N)`, under
  the same build-directory locks and with the same safety checks before a
  build directory is removed; Ctrl-C stops it there (a removal stops between
  entries). The editor shows a clean started in a terminal as its own:
  `cleaning`, then `cleaned` or `clean failed`. `lw nuke` and `lw device
  clean` still run in-process. The daemon protocol is now version 8:
  an older daemon is restarted when idle. (#137)
- Experimental daemon (`runtime-mode daemon`): the editor now shows an
  operation started in a terminal (`lw build`, `lw test`, `lw run`) exactly
  like its own: the profile row's progress, timer and spinner, the units'
  running state on the status page and in the statusline, the same fidget
  entry and end message, and normal Tasks rows, each with a dim `lw` (or
  `editor`) marker naming who started it; Enter offers `Show output` (no
  cancel). Operations already running when the editor connects are picked up
  too. `lw status` lists a busy daemon's running tasks under its `Runtime`
  row (operation, profile, origin, elapsed, percent), asking the daemon for at
  most about a second and never starting one. The daemon protocol is now
  version 7: an older daemon is restarted when idle. (#132)
- Experimental daemon (`runtime-mode daemon`): `lw run` now builds, deploys
  and resolves the launch in the workspace daemon, with the same output and
  exit code, after one dim line `lw: preparing the run through the workspace
  daemon (pid N)`; the program itself still runs in your terminal, as the
  `lw` process's child, so stopping or restarting the daemon never touches it
  and no lock is held while it runs. Runs on a device stay in-process and say
  so in one line. The daemon protocol is now version 6: an older daemon is
  restarted when idle. (#130)
- Experimental daemon (`runtime-mode daemon`): `lw test` (the batch form,
  `lw test [<profile>] [--junit <file>] [-- <args>]`) now runs in the
  workspace daemon like `lw build`, with the same output, JUnit files and exit
  code, after one dim line `lw: testing through the workspace daemon (pid N)`;
  Ctrl-C stops it there. `lw test --target` (local or on a device) still runs
  in-process and says so in one line. The daemon protocol is now version 5: an
  older daemon is restarted when idle. (#129)
- Experimental, opt-in (`runtime = { mode = "daemon" }` in the plugin setup,
  or `LOOMWORKS_RUNTIME=daemon`): the editor connects to the workspace daemon
  and shows the builds it runs, such as `lw build` in a terminal, as fidget
  progress, `building` units on the status page and in the statusline, and a
  `(daemon)` row in the Tasks section with the build's output. The editor's
  own builds still run in the editor. It starts the daemon from the `lw` it
  finds (`LOOMWORKS_LW`, the pinned `lw`, `lw` on `PATH`) when a workspace
  opens or on `:LoomworksDaemon connect`, never after `lw daemon stop`, and
  picks up the daemon's build results at once. (#128)
- `lw cleanup` lists what lw left behind outside the workspace after an
  interrupted run (partial downloads and staging directories, temporary
  files, a dead holder's device lock, a stale daemon socket, files earlier
  versions kept outside the workspace), with sizes; `lw cleanup --yes`
  removes them, `--all` also prunes pinned releases no repository has used
  for 30 days (`--pinned-older-than 90d`). lw also removes such leftovers by
  itself, silently, once a day at the start of a command. (#122)
- `lw daemon list` (experimental daemon): every workspace daemon of yours on
  this machine with its root, pid, uptime, state, clients and version, found
  by scanning processes (nothing is written outside your workspaces); `--json`
  for scripts, `--under <dir>` to narrow. `lw daemon stop --all` and
  `lw daemon kill --all` stop each one through its workspace's runtime lock;
  `kill --all --strays` also kills leftover daemons that are no longer their
  workspace's runtime. `lw health` counts running daemons. (#120)
- Experimental, opt-in (`runtime-mode daemon`): `lw build` runs in the
  workspace daemon, in every form (`--target`, `--force`, `--reconfigure`,
  `-v`, `-- <args>`), with the same output, exit code and build state as
  without it, after one dim line `lw: building through the workspace daemon
  (pid N)`. The build runs in the environment of the `lw build` that asked for
  it (sent over the private, authenticated endpoint; never written anywhere),
  Ctrl-C stops it in the daemon, and it takes the same build-directory locks
  as an editor or `lw --no-daemon` build. `--no-daemon`, CI,
  `--break-locks` and interactive profile creation build without the daemon,
  as before. (#113)
- Experimental, opt-in: the setting `runtime-mode` (`in-process`, the
  default, or `daemon`; `LOOMWORKS_RUNTIME` overrides it) prepares the
  workspace daemon. `lw daemon status` and a new `Runtime` row in `lw status`
  show the mode and any daemon from its files; neither ever starts one. (#105)
- Experimental: `lw daemon run | stop | kill | restart` manage the workspace
  daemon. Its endpoint is restricted to your user and every connection must
  prove this machine's key; `stop` never kills, `stop --force` and `kill`
  recover a hung daemon. (#106)
- Experimental: with `runtime-mode daemon`, every workspace command keeps the
  workspace daemon running (it only answers status requests for now; nothing
  runs through it yet). `--no-daemon`, `LOOMWORKS_NO_DAEMON=1` and `CI=true`
  never start it; it exits after `daemon-idle-timeout` (default 45s) without
  clients, or when the workspace is removed. Kills and forced unlocks are now
  recorded in the workspace's runtime log, `.nvim/loomworks.daemon.log`
  (`lw daemon status` names it). (#107, #121)
- Operations that change several workspace files at once (publish, import,
  pull, cache-propagating renames, profile removal, reset, nuke,
  `lw trust --discard`, and the editor's delete / reset / nuke) take a
  workspace operation lock: a second one fails at once with `workspace busy`
  instead of interleaving its writes. `lw unlock --workspace` clears it when
  its holder is gone. (#100)
- `--break-locks` (and `--break-locks=now`) on `lw build`, `clean`, `reset`,
  `run`, `test` and `lw device clean` (and, with the workspace operation lock,
  `nuke`, `publish`, `import`, `pull`, `migrate`, `trust`, `project` /
  `config` / `configset` `rename` and `publish`, `profile publish` and
  `profile remove`) recovers a stuck lock: it asks the
  holder to stop, waits about 5 s (`=now` skips the wait), kills its process
  tree, recovers the interrupted step's state and runs. It never touches a
  process on another host or an editor, and works under `--no-input`. (#99)
- `lw unlock --force <profile | build dir>` removes a lock record without
  stopping its holder, with a loud warning; `lw unlock` also takes a build
  directory path. (#99)
- `lw export` prints the whole workspace configuration as a `loomworks.json`
  (local items included, machine-local settings never) without writing
  anything; `--published` prints exactly what `lw publish` would write,
  `--no-profiles` leaves profiles out, `-o <file>` writes a file. (#93)
- `lw import <file>` (or `-` for stdin) replaces the working configuration with
  an export from another machine: it shows what changes and the program
  settings it will trust, asks (`--yes` to skip, `--dry-run` to only look),
  keeps this machine's own settings, publishes nothing, deletes no build
  directories, and saves the previous working copy as a timestamped `.bak`.
  (#93)
- Experimental daemon mode: Ctrl-C during a build, test, clean, reset or run
  preparation that runs in the workspace daemon now asks the daemon to cancel
  it and waits until it has stopped (`lw: stopping the <op> - press Ctrl-C
  again to stop waiting`, then `<op> stopped: ...`, exit 130); a second Ctrl-C
  leaves at once while the daemon finishes stopping it. After a Ctrl-C `lw run`
  never starts the program, even when the preparation had just finished.
  Against an older daemon the first Ctrl-C leaves at once, as before. (#176)
- New lualine component `loomworks_lsp`: placed next to `lsp_status`, it
  shows `(unconfigured)`, `(no db)` or `(ws error)` in red when loomworks
  withholds clangd for the buffer. `buf_status()` gains an `lsp` field and
  `loomworks.lsp_buf_state(bufnr)` returns the same per-buffer status. (#191)
- Saved test targets: a configuration (or a whole project) can list test
  programs in `tests` - a build target or a launch configuration, as
  `"Name"`, `["Name", "arg", ...]` or
  `{ "name": "Name", "args": [...], "working_dir": "..." }` (args and
  working_dir take `${...}` variables; a name may repeat with different
  args) - and plain `lw test` runs them after the
  project's ctest / `meson test` run, on a device for a cross-compiling
  profile. `--saved` / `--discovered` run only one kind, `lw test --list`
  shows the plan (and whether each entry is a target or a launch) without
  building, and `lw test-target add/remove/clear` edits the lists
  (`add --working-dir <dir>` writes the table form). A build-target entry
  runs in the project directory unless its working_dir says otherwise, and
  the new `${target_dir}` variable names the directory holding the
  executable being run (launches with a target, saved entries,
  `lw test --target`, which also takes `--cwd <dir>`). The status page shows
  a read-only `Tests:` line, and the test explorer and neotest pick the saved
  targets up. (#208) With `runtime-mode daemon`, the workspace daemon runs
  the whole plan, saved targets included, with the same output; a plan that
  runs saved targets on a device stays in the `lw` process. (#212)
- The deploy editor offers `${target_dir}` in its destination segment picker
  for a project's deploy steps (not for a command launch's, where it is
  unavailable). A project-level step also runs for the project's command
  launches, so a project-level destination using `${target_dir}` fails the
  deploy of a command launch. (#214)
- Experimental daemon: the workspace daemon can run the editor's selected
  tests (`Tests/1.run_cases`: build what the selection needs, then run each
  test program with per-case progress and results) and prepare a test for
  the debugger (`Tests/1.prepare_debug`, then `collect` reads the results
  the program wrote), and keeps each test's last result and output for the
  session. Running all tests runs every test program of the profile and
  first discovers the projects whose tests were not discovered yet or are
  out of date after a build; a second run of the same build directory waits
  for the first. The editor starts using them in a later step. (#223)

### Changed
- In `daemon` mode the status page's Debug Adapters section lists the
  languages of the daemon's `DebugConfig/1.adapters` records instead of
  reading the editor's model. `DebugConfig/1.adapters` now has one record
  per language of the workspace's modules, as the in-process section shows,
  instead of one per known language. The launch editor's "Add debug
  language" still offers every known language: it reads
  `DebugConfig/1.known_languages`. A launch's debug language that no module
  declares shows "(resolved at launch)" as its adapter in the launch editor.
  (#343)
- The profile row's "+ Add tool" offers the toolchains of the profile's
  configuration set, its SDKs' kit toolchains among them, and is hidden for a
  profile whose set is missing. In `daemon` mode the configuration-set
  templates come from the workspace daemon, and the status page names
  mappings by id. (#345)
- The status page's configuration-set edit dialog and the create dialog's
  custom set list the projects and configurations the status page shows,
  CMake presets included, instead of reading the editor's own copy of the
  workspace. The create dialog's suggested sets still come from the editor's
  copy for now. A set mapping a project to a configuration that is gone or
  does not exist is refused when saved, naming it, the same way in both
  modes; a mapping to a preset or to a configuration whose source is missing
  saves in both (#339).
- In daemon mode the status page's builds, serial builds, configures, cleans
  and rebuilds of a profile or of one of its configurations name it to the
  workspace daemon by the id the status page shows, never by its name: a
  profile or configuration changed meanwhile is refused instead of acting on
  another one, and a configuration not yet known to the daemon offers no
  operation. The question whether to overwrite another profile's built
  artifact and the clean confirmation come from the status page's own rows;
  a clean first stops only the editor's own tasks on it. A rebuild builds only
  after its clean succeeded. Whether there is anything to clean is decided by
  the clean itself, not by the status page: a configuration whose build
  directory was deleted, or whose project has no clean command, reports
  "nothing to clean" as information, and its rebuild goes on to build. (#333)
- `lw clean` with nothing to clean prints its "nothing to clean" line as an
  ordinary output line on stdout instead of an `lw:` error on stderr; the
  exit code stays 1. (#333)
- In daemon mode the rest of the status page's Profiles actions name their
  rows by id too: the build options float (`o`) reads them from the
  workspace daemon, the device choice is sent by the profile's and the
  device's ids, and a profile's or configuration's cancel, task output
  (`<CR>` / `t`, now also for a task that already ended) and progress are the
  tasks the daemon reports for that profile, or for a configuration the
  tasks that run that configuration: a task of its profile that does not run
  it (a device log, a device install or launch, a test discovery) is not the
  configuration's, so its cancel no longer stops such a task and `<CR>` no
  longer opens its output. A configuration's cancel stops the editor's own
  task that runs it, even the whole profile build; a task started elsewhere
  (`lw`, another editor) is not cancelled; the status page says to cancel it
  there. Before a confirmed deletion the editor stops only its own tasks on
  exactly what is deleted, no longer every task that merely shares a project
  name or a path, and the confirmation lists every task it stops, including
  one that has not started yet. A project deletion stops the editor's own
  tasks on every configuration of the project, also one no profile uses. A clean (`C`) now always goes to the daemon.
  It first stops the editor's own work on those configurations, even when
  the daemon then reports nothing to clean: for example, a clean pressed
  during a first configure stops that configure. Only a clean's "nothing to
  clean" counts as success; another operation refused the same way is
  reported as an error. (#335)
- Experimental daemon: in daemon mode, when the workspace failed to load (for
  example a working copy or build cache refused by trust), the status page's
  trust (`T`), discard (`U`) and reset (`<C-n>`) no longer run in Neovim: they
  are refused with a notification naming the command to run instead
  (`lw trust`, `lw trust --discard`, `lw nuke`); press `L` afterwards to load.
  (#329)
- The status page's `D` on a project now also deletes the project's build
  state: after a confirmation listing its build directories, they are
  deleted, then the project is removed from the configuration and its
  profiles' toolchains are downgraded (it used to remove only the
  declaration and leave the build directories behind). (#326)
- In daemon mode the status page's deletions (a profile, a configuration, an
  orphaned or stray build directory, all orphaned ones, a project, also from
  the project browser) and `<C-n>` (reset the workspace cache) run in the
  workspace daemon: the confirmation lists what the daemon will delete, the
  editor's own running tasks on it are stopped first, and the result is
  reported once the deletion has finished. A refusal is an error
  notification and deletes nothing; it is never done in Neovim instead. (#326)
- In daemon mode the status page's launch and deploy editors read and save
  through the workspace daemon, and their path previews are expanded there
  (they appear a moment after the dialog opens). The deploy step editor's
  target picker offers the targets of the units profiles use. (#323)
- The status page's configuration editor lists every build directory of the
  configuration (one per toolchain it was configured with), sorted, instead
  of one picked in no fixed order. In daemon mode it reads the configuration
  and saves it through the workspace daemon, and its variables show the
  values of the active profile's compiler family, as the status page now
  does too. (#322)
- Every usage error now exits 2 (it was 1 for many of them): an unknown,
  repeated or misplaced option, a missing or malformed value (`--timeout 0`,
  an invalid launch name, an unknown `lw config set` parameter or health
  area), an empty value, an extra operand, and a missing operand lw cannot
  ask for, such as no profile named in non-interactive mode. An error about
  the workspace's state, such as no unambiguous default profile, still exits
  1 (#290).
- Every option that takes a value now also accepts it joined with `=`, on
  every command: `--working-dir=build`, `--env=PORT=8080`, `--cwd=out`
  (the split is at the first `=`) (#290).
- An option that holds one value is refused (exit 2) when it is given twice,
  instead of the last one winning. This includes `--cwd` with `--working-dir`,
  `--working-dir` with `--clear-working-dir`, and `--command` with
  `--from-target` on `lw launch set`. `--env`, `--unset-env`, `--description`,
  `-m`, `--prefix`, `--target` and `--log` may still repeat (#290).
- An empty option value is refused (exit 2), as in `lw run --cwd= app`, except
  where `""` clears: `--working-dir ""` and `--description ""` on
  `lw launch set`, `--working-dir ""` on `lw launch add` (no working
  directory), and `-m ""` on `describe` (#290).
- A value that starts with `--` must now be joined with `=`
  (`--working-dir=--odd`, `lw run --prefix gdb --prefix=--args`): a valued
  option followed by `--`, by another `--` token or by nothing is a missing
  value (exit 2) (#290).
- On `lw launch add <project> <name> <command>`, every token after the command
  is the program's, including lw's own options: `--env`, `--working-dir` and
  `--description` go before the command (#290).
- `lw launch set` no longer turns an unknown option into an argument: an
  unknown option before `--` is a usage error (exit 2) and nothing changes.
  An argument starting with `-` now goes after `--`
  (`lw launch set app run -- --port 1`); bare arguments still work as before
  (#290).

- With the workspace daemon, the editor's devices are the daemon's: the
  status page's device picker and `lw.scan_devices` scan through it (one
  task), `lw.get_devices` returns its device list, and choosing a profile's
  device is saved by it. Launching a device target builds, installs and
  launches it there as tasks the editor owns, and stopping it stops the app
  through the daemon. When the daemon cannot do these they are refused with
  the reason; they never run in the editor. A device-log view that falls
  behind its stream now shows the gap in the view. (#288)
- With the workspace daemon, a device launch opens the device-log view with
  the app's log, streamed by the daemon (before, the log was not available
  with the daemon). The view starts at the log level the device's module
  suggests, shows records the daemon had to drop as a gap line, and says when
  the stream ended. Closing the view or stopping the run stops the stream;
  opening the view again while the app runs starts a new one; once the run
  is over it only shows the view. The daemon keeps the log's first lines
  until the view has subscribed, so none is lost at the start. (#291)
- With the workspace daemon, the editor's *Build default target* of a
  non-device target is one daemon task: the daemon builds the target's
  dependencies, runs its pre-build deploy and builds it (the editor no longer
  runs the deploy or orders the builds itself), and the progress entry, the
  status page row and the overseer row show its current step (e.g.
  `dependency lib (1/3)`); launches show their steps the same way. The
  question about overwriting another profile's output artifact is now asked
  before the build or launch starts, and answering Yes builds anyway. Device
  targets still build in the editor. (#263)
- `lw project show`: the project's tests row reads `none project-wide` instead of
  `none` when the project has no project-wide saved test targets, so it no longer
  looks like there are no tests when a configuration has its own. (#252)
- `lw test --target` now passes the results option (e.g. `--gtest_output`)
  first, before the entry's arguments and the arguments forwarded after
  `--`: program, results option, args. Before, the results option came
  last. (#208)
- Debugging a module target (an executable a build produces) now starts it
  where and how it runs: in its working directory (the launch target's
  `working_dir`, else the project directory) with its run environment (the
  build tree's library paths), instead of in its build directory with no
  environment. A target-backed launch configuration is debugged with its
  arguments, environment and working directory, as it runs, also for a
  single debug language; a launch configuration's debug session is named as
  its run. (#201)
- Experimental daemon mode: the statusline component and the status page
  header show the workspace daemon's view while the editor is connected to
  it, including `Workspace: not loaded in the workspace daemon` until the
  daemon loads the workspace, and the editor's own model otherwise. The
  Runtime line names `statusline` and `project index` when the daemon does
  not offer them. (#188)
- `lw.buf_status()` (and so the statusline) now returns the buffer's project
  when no profile is active: `project` is set, `profile_key`, `set_name`,
  `configuration`, `tool_key` and `status` are nil, so the statusline shows
  the bare project name instead of nothing. `tool_key` is now the tool of the
  buffer's project in the active profile (the profile's per-project tool),
  not the project's own tool. (#188)
- The machine-level tool cache (`tools.json`) is now reused per module type
  only while what the detection depended on is unchanged: another `lw`
  version, a changed `PATH` or `PATHEXT`, or a compiler newly installed into a
  directory on `PATH` re-detects just the affected module types, in the CLI
  and in the experimental workspace daemon alike, so a restarted daemon starts
  warm without serving stale toolchains. A toolchain found outside `PATH` (a
  registry or installer query) or upgraded in place still needs `lw tools`.
  Each module type is written as soon as its detection finishes, never half
  written; older releases keep reading the file. Housekeeping and
  `lw cleanup` remove a leftover temporary file of an interrupted write after
  24 hours. (#183)
- Experimental daemon: with no `daemon-idle-timeout` set, an idle daemon now
  exits after 45 seconds without clients or background work instead of 1
  hour, so a script of several `lw` commands still shares one daemon but
  nothing lingers; set `daemon-idle-timeout` (e.g. `1h`) to keep the old
  behaviour. An attached editor keeps the daemon alive as before. (#182)
- Experimental daemon mode: the editor connects to the workspace daemon only
  through `lw daemon run --root <dir> --stdio` - the same shared daemon as the
  CLI - and no longer reads the daemon's handle or launches it itself. On load
  and on `:LoomworksDaemon connect` the relay connects or starts the daemon;
  after `lw daemon stop` (or any drop) the editor waits through a
  `--no-launch` relay and never restarts it, and it follows a daemon the CLI
  starts later. With no host binary the editor stays in-process and no longer
  observes a daemon another client started. A relay that fails before the
  daemon answers is one note on the Runtime line; a pinned `lw` too old for
  the editor's relay flags is named there. Until a later step, an
  incompatible daemon the editor does not observe leaves it in-process until
  `:LoomworksDaemon connect`. New relay flag `--no-launch --retiring
  <pid>:<start_time>` waits for that retiring daemon to exit (status 16), and
  a relay that gives up on a retiring daemon (status 14) names it on its last
  standard-error line, `retiring <pid>:<start_time>`. (#178)
- In `runtime-mode daemon`, a workspace daemon the editor cannot use and does
  not retire (newer file formats, no common protocol, busy and then gone, or
  one it already retired this session) no longer leaves the editor
  in-process until `:LoomworksDaemon connect`: it keeps working in-process
  and connects to the next daemon started for the workspace, without
  starting one itself and without connecting back to the one it left. A
  daemon whose start time is unknown still waits for
  `:LoomworksDaemon connect`. The editor retires a daemon only through the
  shared-daemon relay, never an older pin's attached `--stdio`. (#179)
- Experimental daemon: `lw daemon run --root <dir> --stdio` is now a relay to
  the workspace's shared daemon (starting it when none runs) instead of a
  private daemon of its own, so a client on standard input and output shares
  the daemon with every `lw` command; closing it closes only its connection.
  `--no-launch` never starts a daemon and waits for one to appear;
  `--skip-instance <pid>:<start_time>` (with `--no-launch`) never uses that
  daemon. Failures before the daemon's welcome exit with statuses 10 to 16.
  (#173)
- Experimental daemon: `lw daemon list` no longer shows a `lw daemon run
  --stdio` relay as a daemon (a stray, once it was 30 s old): a relay is a
  connection, listed in `--json` as `relays` (pid and start time) on its
  workspace daemon's entry, and `lw daemon stop --all` / `kill --all
  [--strays]` never stop or kill it. A `--stdio` process that holds its
  workspace's runtime lock (a release before the relay) is still a daemon.
  One such older `--stdio` runtime that no longer holds that lock (taken
  over, unreadable, or its workspace deleted) now counts as a relay: it is
  not listed as a stray and `kill --all --strays` leaves it running; end it
  with the operating system's tools. (#174)
- Experimental daemon: an idle daemon now waits for its own background work
  (tool detection after a snapshot or query, a cancelled build or a reset's
  deletion still settling) before the idle timeout starts counting, and
  `idle_since` is absent from its handle meanwhile. Background work left
  running with no connection open is capped at 10 minutes: tool detection is
  then abandoned (the model is unloaded and loaded afresh by the next
  request), and a build or reset still settling stops the daemon, its
  deletion stopping between entries with their cache entries left
  `unknown`. (#175)
- In a repository with `lw.pin`, a global lw now also runs `lw reset`,
  `lw daemon run` and `lw daemon restart` as the pinned release, so the
  workspace daemon is the pinned release whoever starts it (the editor
  included); the other commands a global lw runs itself there no longer start
  or replace that daemon. A pin naming a release that predates one of those
  commands is not followed for it: `lw reset` then runs as the global lw, and
  `lw daemon run` / `restart` refuse rather than start a daemon of the wrong
  release. For a daemon command its `--root` decides which `lw.pin` applies,
  also under `./lw.sh`. (#155)
- Experimental daemon mode (`runtime-mode daemon`): `lw` now compares its own
  version with the one the workspace daemon reports for itself before using
  it. A daemon counts as busy only while a client runs an operation on it or
  waits for an answer, so an editor that only watches never keeps an `lw` of
  another version from restarting an idle daemon; the editor reconnects to
  the new daemon by itself. A retiring daemon exits as soon as nothing runs.
  The editor now receives task output and model changes from a current
  daemon through subscriptions, and still works with older daemons; an
  interface the daemon does not offer is shown as one note on the status
  page's Runtime line, and one the daemon starts offering later is picked up
  without reconnecting. The daemon log notes a request still unanswered
  after 10 minutes. (#153)
- Experimental daemon mode (`runtime-mode daemon`): `lw --no-daemon`, CI runs
  (`CI=true`, `LOOMWORKS_NO_DAEMON=1`) and a daemon that could not be started
  now run `lw build`, `lw test`, `lw run`'s preparation, `lw clean` and
  `lw reset` with the workspace daemon's own code inside the lw process,
  holding the workspace for the command (spec 19.1, 19.19 step 5e). A running
  daemon is used instead. A second such command in the same workspace waits
  `runtime-busy-wait` (new setting, default 5s) and then fails with
  "workspace busy" (exit 1); so does a normal daemon-mode command that finds
  such a command running. A running daemon of another lw version is stopped
  when idle (the command then runs inside lw, nothing is started in its
  place) and bypassed when busy. If the command loses its hold on the
  workspace, its running build steps are stopped, no workspace file is
  written after that, and it exits 1 (also after a `lw reset` confirmation).
  `--break-locks` given with one of these selections runs the same way. The
  default `in-process` mode is unchanged. (#148)
- Experimental daemon in the editor: the plugin now also follows `lw`'s own
  setting (`lw settings set runtime-mode daemon`), after `LOOMWORKS_RUNTIME`
  (and `LOOMWORKS_NO_DAEMON` / `CI`) and the setup option `runtime.mode`; it
  reads the setting on each workspace load and never writes it. The status
  page's `Runtime:` line is now the header's last line, names the mode and
  what chose it (`env`, `setup`, `lw setting`, `default`), and is hidden only
  when nothing chose. A daemon of another protocol or file format is named
  there in the warning colour with both versions and the fix (update the
  plugin, or pin or install a matching `lw`). (#131)
- `lw cleanup` (without `--all`) now lists the runtime logs earlier versions
  kept in the data directory (`daemon/logs`) whatever their age: they are
  always leftovers now that the log lives in the workspace. `--all` adds only
  the pinned releases unused for 30 days, as its help now says. The automatic
  daily pass still waits 30 days for those logs. (#126)
- `lw daemon list` STATE uses the documented states: `live` (with `busy` or
  `idle <time>`), `starting`, `hung`, `stray`, `unknown root`; a daemon that
  was just launched and has not taken its workspace's lock yet is `starting`,
  not a stray. Every column is filled (`-` when unknown), a stray's reason
  follows its root, and a development build's version is shortened. (#126)
- `lw daemon list` marks a daemon started with another loomworks data
  directory (another `LOOMWORKS_DATA_DIR`, such as a test run's) as
  `other data dir` (`--json`: `same_key`), and `lw daemon stop --all` /
  `kill --all` skip it with a plain message instead of calling its endpoint
  untrusted; it no longer makes the command exit 1. (#126)
- In daemon mode, `lw build` waits up to about 5 seconds (instead of about one)
  for a slow but healthy workspace daemon to answer before running the build
  without it: under machine load the build no longer falls back in-process
  exactly when the daemon helps most. Other commands keep the one-second
  bound, and a daemon that stopped responding is still reported at once.
  (#124)
- `lw test <target>` writes its gtest results file, and `lw ... describe -e`
  its editor buffer, in the workspace's `.nvim/tmp/` instead of the system
  temporary directory, and removes them after use: an interrupted run no
  longer leaves them outside the workspace. (#121)
- `lw import`: an item the working copy already has keeps its intent (local or
  local+shared); only new items take theirs from `loomworks.json`. Exporting
  and importing on the same workspace no longer turns shared items local.
  `--shared` and `--local` still override. (#102)
- `lw import` keeps the workspace's own name instead of taking the exported
  one; the summary shows the export's name when it differs, and the new
  `--take-name` option adopts it. (#104)
- `lw import` replaces a working copy that is not signed by this machine (for
  example one written by an older `lw` in a worktree) instead of refusing:
  `--dry-run` always works, and a confirmed import replaces the file unread,
  keeping a backup and none of its settings. (#102)
- A lock left by a process that crashed or was killed is taken over at once
  (it used to wait about 20 s), and the interrupted step is recovered: a killed
  configure leaves its configuration unconfigured, a killed build step leaves
  it configured. Every lock now records the holder's process start time, so a
  reused process id is never mistaken for the holder. (#99)
- The working copy and the build cache record the loomworks version that wrote
  them. A file whose format is newer than the running loomworks understands is
  never rewritten: the workspace is not loaded and the message asks you to
  update loomworks (it no longer offers to reset the cache or delete the
  working copy). A file from a newer loomworks with the same format loads with
  a one-time warning. (#94)
- A save that finds the working copy changed on disk by another `lw` or the
  editor since it was read writes nothing, reloads the file and reports that
  the change must be redone (an error in the editor; `lw` exits with 1). (#94)
- `lw status` ends with the everyday commands (build, run, test, clean,
  reset, health, pull, worktree add, publish) and points at `lw help`; outside
  a workspace it points at `lw help` too. (#90)
- A fresh git worktree with no profiles is told that `lw pull` copies the
  main checkout's profiles. (#90)
- Next-step hints: `lw init` names `lw project add`; `project add` and
  `config add` name the `lw configset create`/`map` and `lw config list`
  commands; `configset create` and `profile create` hints name `lw tools`;
  `profile create` names `lw build <profile>` and `lw profile select`;
  an empty `lw profile list` names `lw profile create`; `lw worktree` names
  `lw worktree add`; `lw install` ends with `lw init` / `lw help`. (#90)
- `lw profile show` names a non-active profile in its hints (they used to
  act on the active one), adds `lw test` and `lw reset`, and offers
  `lw profile describe` when the profile has no description. (#90)
- `lw help` lists every command and sub-command (`unlock`, `profile set`,
  `launch rename`, ...), indexes the help topics, and the help topics document
  every accepted option (`run --working-dir`, `launch add --cwd`,
  `device clean --no-wait`, `profile create -a`, `-v`/`--version`, the
  `release-notes` setting, ...). (#90)
- Editor (daemon mode): the `lw` the editor starts the workspace daemon from
  is now `LOOMWORKS_LW`, then the new setup option `binary.path`, then `lw` on
  `PATH`, then an `lw` the plugin manages under Neovim's data directory
  (`binary.prefer = "managed"` tries that one before `PATH`). Only absolute
  `PATH` entries are searched, never the current directory, so an `lw` shipped
  in an opened repository is never started; on Windows each entry is checked
  for `lw.exe`. An explicit path is taken against the editor's current
  directory once, when chosen; one that names no file (on Windows, no `.exe`)
  stops there with a note. The editor no longer reads
  `lw.pin` or starts lw's provisioned pinned binary itself. The status page,
  `:LoomworksDaemon status` and the new `:checkhealth loomworks` say which
  `lw` was chosen and why, or why none. `binary.source` (development only)
  runs it with a Lua source tree. (#154)
- Inside a workspace, clangd only gets a compile database from the active
  configuration as configured on this machine. A stale
  `compile_commands.json` in a build directory that is not configured here
  (never configured, reset, or copied from elsewhere) is no longer used, and
  a buffer under the workspace root with no usable database gets no clangd
  client at all instead of one that guesses flags. clangd starts by itself
  once the database exists (configure finishes, or you switch to a
  configured profile) and stops when you switch to an unconfigured one.
  This needs loomworks' default clangd setup, or your own `vim.lsp.config`
  + `vim.lsp.enable` (Neovim 0.11+). Files outside the loaded workspace,
  including a file of another workspace that is not loaded, keep your
  stock clangd. (#191)
- Deleting or resetting a build directory (editor `D`, `lw reset`,
  orphan delete) now also removes the compile database loomworks generated
  from it under `.nvim/cache/cc/`, and nuke (`<C-n>`, `lw nuke`) removes the
  whole `.nvim/cache/cc/` area. Nothing else under `.nvim/cache/` is touched;
  a database still used by another build directory is kept, and nothing is
  removed through a symbolic link or junction (nuke refuses entirely if the
  area is one). (#191)
- The winbar marker for an unconfigured configuration is now red, and a
  profile whose configurations disagree (`mixed`) is amber. The status page
  says "clangd withheld" with the reason. (#191)
- The lualine/winbar status markers now take only the colour of their
  highlight group and keep the lualine section's background; the text after
  a marker no longer falls back to the plain statusline/winbar colours. (#191)
- Configuring a profile in the editor now runs configure for every
  configuration of the profile, including ones already configured, instead
  of skipping them; one in an unknown state still has to be cleaned or
  deleted first. Its progress finishes only when those configures have run,
  even if they had to wait for a build in progress. Building still configures
  only what needs it. (#196, #198)
- `lw project show` always prints the project's saved test targets row, with
  `none` and the `lw test-target add` form when there is no project-wide list,
  and prints each configuration's effective list with its source (for example
  `inherited from Tests`). (#241)
- `lw project show` lists a configuration's saved test targets only when it
  has some; the project row still always shows. (#242)
- `lw project show` without a name shows the only project, or lists the
  projects when there are several. (#247)
- In a repository with `lw.pin`, workspace commands print `loomworks <version>
  (pinned)` to stderr instead of always claiming to fetch; `fetching loomworks
  <version> (pinned)...` appears only when the pinned release is really
  downloaded, including on a first run through `lw.sh` / `lw.cmd`. (#262)

### Fixed
- Renaming a project no longer throws away its configured and built build
  directories' state on the next reload: the project's configurations keep
  their build state and are not reconfigured from scratch (#341).
- A toolchain rescan (or an SDK add or remove) no longer misses its toolchain
  change when an earlier, slower detection finishes during its wait: only the
  newest detection is taken in, and the editor's view is told about the
  change (#337).
- The workspace daemon no longer stalls other clients while a saved `launch`
  test entry deploys before its test runs, or while the project browser's add
  detects a module's toolchains: both now run without blocking, and a cancel
  stops a test run's deploy between copies (#337).
- The status page and the daemon's workspace view no longer walk
  `.nvim/build` on every refresh to find stray build directories; the scan
  reruns only when a build directory or the scanned tree changed (#337).
- A publish, rename, profile removal, import or toolchain change whose
  multi-file commit failed (or which hit an internal error) kept its change
  in memory although nothing was written, so the editor and the workspace
  daemon showed a state that was not on disk and the next save was refused as
  stale. The workspace is now reloaded from disk in that case, and every
  project, configuration set, profile and configuration keeps its identity
  (the active profile and running builds stay as they were) (#338).
- A multi-file commit that failed while replacing its files (after its
  commit journal was written) was reported as failed, yet the next operation
  completed it. The writer now completes it at once and reports success;
  only a commit that cannot be completed fails (#338).
- A state listener that failed while a config was marked deleting or
  cleaning could leave it shown as "deleting" until a reload (#338).
- A clean whose wipe step removes the build directory showed the config's old
  state, not "cleaning", for the rest of the clean (#338).
- A deletion that hit an internal error before it started removing anything
  could leave the config shown as "deleting" until a reload (#338).
- A failed clean during a configuration rebuild (`R`) was reported twice
  (#338).
- A failed removal of a stray build directory did not say why in the log
  (#338).
- Rebuilding a configuration from the status page (`R`) built even when its
  clean failed; it now stops and reports the failed clean (#328).
- A failed, stopped or refused clean no longer leaves the config shown as
  "cleaning" for the rest of the session (it also blocked removing or
  renaming that config); the same holds for a deletion that errors before it
  finishes (#330).
- The launch editor never offered `${target_dir}` in the path and deploy
  editors it opens (arguments, working directory, deploy steps). It now does
  for a target-backed launch; a command-type launch still does not, since
  `${target_dir}` is unavailable there. (#325)
- The status page's configuration editor never showed where a
  configuration's variant comes from ("from X"; none when the
  configuration sets its own variant) nor its read-only compiler-family
  overrides. It does now. (#322)
- In daemon mode a project just added from the status page could not have
  its configurations edited or added until the editor reloaded. (#322)
- In daemon mode a project just added from the status page could not have
  its launch configs, deploy steps, variables or fields edited or added until
  the editor reloaded. (#323)
- A profile created from an SDK in the status page's tool picker lost its
  SDK on the next load: it was saved without toolchains, came back as the
  configuration set's toolless profile, and its key clashed with an existing
  toolless profile of that set. It now stores the SDK's kit toolchains as
  its tools, as picking the kit does. The picker offers an SDK only when it
  yields a kit for the set's project types. (#311)
- `lw profile create` for a profile that already exists no longer resets its
  intent to `local`; only a new profile starts `local`, so re-running it on a
  published profile keeps it published. (#310)
- A deletion whose `unknown` cache marks could not be saved (the runtime
  lost its workspace lock, or the workspace was unloaded while the deletion
  waited for its tasks to stop) still removed the build directories, leaving
  the cache claiming trees that were gone. It now removes nothing, reports
  every item as failed with the reason, and leaves the entries as they were
  (#302).
- Deleting a single orphaned build directory from the status page could
  remove a live build: an orphan whose directory contains the live one (the
  build-directory template gained a level, `build/proj` -> `build/proj/Debug`)
  or is the live one under another spelling (an 8.3 short name). It now gets
  the same protections as the bulk orphan cleanup: such a tree is kept and
  only the stale entry is dropped. Its completion message now says whether
  the directory was removed, kept (and why), or not removed, instead of
  always reporting it removed. `lw reset --all` still removes an orphaned
  directory that contains build directories the reset itself removed, so it
  no longer fails with "could not be removed" there (#302).
- When two entries of one deletion named the same build directory under
  different spellings (a long path and its 8.3 short name, such as
  `C:/Users/RUNNER~1/...`), only the entry whose spelling was removed first
  was marked `unknown` on disk before the removal, and its owned LSP database
  could survive; `lw reset --all` could also refuse an orphaned directory that
  only held a build directory it had just removed under the other spelling.
  Deletions now compare build directories by the directory itself, not its
  spelling, everywhere (#308).
- The editor's project removal, orphan cleanup and stray build-directory
  deletion now take the workspace operation lock and the build-directory
  locks, like every other deletion: they are refused, with the holder named
  and nothing removed, while another process (an `lw` command or another
  editor) is configuring or building the directory or holds the workspace,
  instead of deleting a directory still being created. (#292)
- `lw launch add <project> <name> --from-target <target> ... -- <args>` stored
  the `--` as the first argument. A target-backed add has no command token, so
  its `--` is lw's separator and is dropped; before it an unknown option or a
  bare argument is a usage error instead of becoming an argument (#290).
- `lw launch set <project> <name> --description text` replaced the config's
  arguments with `--description text`; it now sets the description (#290).
- `lw launch describe -m <para> --project P --launch N` took the paragraph as
  the project name when `-m` came before the address (#290).
- `lw launch set ... --working-dir` with no value cleared the working
  directory, and `--command` / `--from-target` with no value stored none; a
  missing value is now a usage error and nothing changes (#290).
- `lw <kind> describe <item> -- <text>` refused the `--`; it now ends lw's
  options, so a description may start with `-` (#290).
- `lw launch show --json <project> <name>` refused `--json` before the
  address (#290).
- Through the workspace daemon, an editor build, run, reset or device
  install of a profile whose key is a number (e.g. a configuration set named
  `2`) now acts on that profile; it could act on the profile at that
  position in the profile list instead. (#294)
- The editor's orphan cleanup no longer drops an orphaned configuration's
  cache entry when removing its build directory failed, no longer removes a
  build directory a live configuration still uses, and marks the entries
  `unknown` before removing anything; it reports a failed removal instead of
  success. A stray build directory that another process configured into after
  the list was shown is kept, and project removal without cached
  configurations now takes the workspace operation lock. (#296)
- Orphan cleanup could delete a live build directory when the workspace was
  reached through a different spelling of the same path (e.g. a Windows 8.3
  short name like `RUNNER~1`): its parent under `.nvim/build` was listed as a
  stray directory. Stray detection now compares directory identity, and
  cleanup refuses any directory that holds a live build dir (#293).
- The status page's *Clean all* of orphaned build directories no longer says
  "cleaned" after a removal failed or was refused; it warns that the cleanup
  is incomplete. A deletion that skips a directory (still used by a live
  configuration) no longer leaves that directory's cache entry `unknown` when
  another removal in the same batch fails (#298).
- `lw device select` fails with the reason when it cannot save the profile's
  device, instead of reporting it saved; choosing a device in the editor
  shows the error likewise. (#287)
- Through the workspace daemon, warnings and errors printed before a build,
  test or run starts are now colored like the in-process output (`--color`),
  and the warnings a read-only command (`lw status`, `lw tools`) raises while
  loading the workspace are no longer dropped, on the request that loads the
  workspace: a warm daemon reuses its loaded workspace and does not repeat
  them. (#279)
- Through the workspace daemon, a warning or error raised while a read-only
  command reads the daemon's workspace is now colored like the in-process
  output (`--color`). (#280)
- The loomtest adapter's `setup()` is idempotent: calling it again (a repeated
  setup in a config) replaces its event listeners instead of adding another
  set, so one profile switch no longer re-renders the test tree once per call.
  New `require("loomworks").off(event, fn)` removes a listener. (#266)
- `lw test`: the end-of-run summary names a failed step's failing tests, like
  the step's own line (at most 10, then `and K more`). (#248)
- Experimental daemon: an editor test run that hit an internal error right
  after the daemon accepted it no longer hangs with its tests shown as queued,
  and a build that hit one after taking its build directory no longer keeps
  that directory locked: the task ends with the error. (#229)
- `lw run --cwd` on a target that runs on a device is now a usage error
  (exit 2) naming the target, like `lw test --target --cwd`, instead of
  exit 1. (#211)
- `lw test` no longer hangs for hours parsing a results file with a very
  large failing test case (for example an assertion failing many thousands
  of times in a loop). (#209)
- A language server is no longer routed to a project whose directory merely
  shares a name prefix with the buffer's (a project at `/a/foo` no longer
  claims a file in `/a/foobar`): the LSP layer maps a buffer to its project
  as `lw.buf_project` does. A file opened through another spelling of the
  workspace's path (a Windows 8.3 short name such as `RUNNER~1`, a junction
  or symlink), or a project whose root is spelled that way, now belongs to
  the project it really lies in; a file reached through a link inside a
  project that points outside it still belongs to that project. (#205)
- Changing an LSP option whose save is refused (a stale or untrusted working
  copy) no longer keeps the unsaved option or restarts clangd; an unknown
  option or a value of the wrong type is refused without writing anything
  (#204)
- A lock file read in the instant between its creation and its record being
  written is read again briefly instead of being judged another host's lock.
  Before, e.g. an editor following the workspace daemon through a
  `--no-launch` relay could stop with "the workspace daemon runs on another
  host (?, pid ?)" while the CLI started a daemon. (#178)
- Lock files are now created with their record already in them and rewritten
  by replacing the whole file, so another process never finds a lock file
  empty while it is being written. Where the file system has no hard links
  (e.g. FAT), a lock file is still created first and filled right after.
  (#180)
- `lw test` notes a project whose kit builds for a device and that has no
  saved test targets, instead of skipping it silently, and says how to
  include it (`lw test-target add`). (#214)
- `lw run --cwd` and `lw test --target --cwd` on a module-declared device
  launch target are now a usage error (exit 2), as for a cross-built device
  target. (#214)
- Test results keep at most 1 MiB of each test case's failure message and
  output; longer captures are cut at a line boundary and end with
  `... [truncated: N more bytes]`. (#214)
- The `unstable` update channel picks the highest release version instead of
  the most recently published one, so a full release published after a newer
  pre-release no longer moves `lw self-update` (and `lw release query
  --channel unstable`) back down to it. (#166)
- A program argument that looks like a global option (`--dev`, `--no-pin`,
  `--no-input`, `--local`, ...) is passed to the program again instead of
  being taken by lw: after `--`, and after `lw launch add`'s command (or
  `--from-target <t>`). Before, e.g. `lw launch set App demo -- --dev` failed
  with "development source requested but no directory is configured" (that
  error now hints to put such a flag after `--`). On `lw launch set` and the
  set-value commands (`lw config|project|profile|settings set`) `--` is the
  escape: every token after it is an argument or the value, verbatim. A
  program's `--help` (`lw launch add app x node --help`) is stored, not
  answered. (#163)
- `lw self-update --force` no longer deletes the release it is running from
  when that is the version it would reinstall: it now refuses with a message
  (run it from another lw version to repair that release). (#156)
- The editor and `lw` no longer restart or retire each other's workspace
  daemon over and over when the same `lw` binary is reached through
  different spellings of its path (`lw.exe` and `lw.EXE` on Windows, or a
  link): a release-less build is identified by the executable's resolved
  path. (#147)
- A command that finds an idle workspace daemon of another version now
  restarts it even while the editor is watching it, instead of treating it as
  busy and running without it. (#147)
- After the workspace daemon it watches retires for a version change and
  exits, the editor starts one new daemon itself and reconnects, instead of
  waiting for a successor forever. A daemon stopped with `lw daemon stop` is
  still never restarted by the editor. (#147)
- The daemon log records each client that connects and disconnects (CLI or
  editor observer, and its lw version). (#147)
- The editor loads a workspace refused for an untrusted
  `.nvim/loomworks.user.json` as soon as that file is valid again (restored,
  or trusted with `lw trust`), and `:LoomworksTrust` on an already-trusted
  file loads it too, instead of keeping the refusal until a directory change
  or `:LoomworksReload`. (#146)
- The editor no longer stays stuck loading the workspace until Neovim is
  restarted after a load or reload fails with an internal error: the next
  reload runs again, and a failed reload keeps the previous workspace. (#145)
- When loomworks.json and `.nvim/loomworks.user.json` both changed on disk
  before the next `lw build`/`test`/`clean`/`reset` through the workspace
  daemon (or the editor's next poll), the operation is no longer refused as a
  stale working-copy save: both changes are applied together. (#144)
- `lw clean` of a project whose build system cleans its own artifacts (cmake,
  meson, a shell project with a clean command) now leaves the profile
  `configured`: `lw status` no longer shows it `(built)` right after a
  successful clean, in-process and through the workspace daemon. The editor's
  clean now also persists the `configured` state, and records it only after
  the clean succeeded. A clean never marks a configuration whose configure
  failed (or whose state is unknown) as configured. (#142)
- Deleting or cleaning a configuration no longer removes a build directory
  that another configuration still uses under a different spelling of the
  same folder (a junction or symlink, a Windows 8.3 short name such as
  `RUNNER~1`): shared build directories are now recognized by their real
  path, and a clean that wipes one folder spelled two ways wipes it once.
  (#139)
- Two operations on one build directory spelled two ways (a junction or
  symlink, a Windows 8.3 short name, a workspace opened through an aliased
  root) can no longer configure or clean it at the same time: the editor's
  operation queue and the cross-process lockfile `<dir>.loomworks-lock` now
  go by the directory's real path, so `lw unlock` finds a lock by any
  spelling too; `lw unlock <build dir>` refuses a path whose real location
  is outside the workspace root. An older `lw` still derives the lockfile
  from the spelled path, so through an aliased spelling (e.g. a symlinked
  workspace root) it and this version do not exclude each other; use one
  version per workspace. (#140)
- `lw clean` on a project that cleans by wiping its build directory (a shell
  project without `clean_cmd`) now treats the wipe as a build-directory
  deletion: the cache is marked unknown before the directory is removed and
  the configuration is reset to unconfigured only after the removal succeeded
  (it no longer claims "built" over a removed directory), a failed removal
  fails the command, and a directory still used by another configuration is
  kept. (#134)
- Cleaning such a project in the editor (`C` on a profile or configuration)
  now has the same safety as `lw clean`: the cache is marked unknown before
  the build directory is removed, the configuration is reset to unconfigured
  only after the removal succeeded, a failed removal fails the clean and
  leaves the configuration unknown, and a directory still used by another
  configuration is kept. In both the editor and `lw clean`, projects of the
  cleaned profile that share one build directory are wiped together (the
  directory is removed once, and `lw clean` no longer reports it as "kept"
  when only the cleaned profile uses it), and a failed removal is always
  reported as a failure, also for a configuration with no cached build
  directory. (#135)
- Removing, resetting or wipe-cleaning a build directory that has recorded
  build state now really writes "unknown" to the cache before the directory
  is removed; before, the cache file kept saying "built" until the removal
  finished, so a crash in between left a stale "built" over a missing
  directory. (#137)
- Experimental daemon: an operation started in a terminal (`lw build`) no
  longer blocks the editor's own. A build from the editor (or build-then-launch)
  was skipped as already running and launched a stale binary, and a single
  build task was refused; they now run and meet the build-directory lock like
  any other process. Unloading the workspace while such an operation runs no
  longer leaves a failed last result on the profile. (#132)
- A save that had to reclaim a crashed writer's lock on the working copy or
  cache, and took longer than the lock wait to do it (a slow, busy machine),
  no longer goes ahead without the lock it just freed. (#127)
- `lw status` says what is trusted: a new `Trust` row shows whether your local
  config is present (signed on this machine) and how many program settings
  in `loomworks.json` are ignored, and a build affected by them prints one
  line saying so (in-process and through the daemon). The status title is the
  workspace's name, so a directory called `untrusted` read like a trust state.
  `lw help trust` no longer says a working copy copied from elsewhere is
  refused: one this machine signed stays trusted in any workspace here; only
  one from another machine (or edited by hand) is refused. (#125)
- Windows, workspace daemon: on a busy machine the daemon could still log
  `could not write the handle: EPERM` and leave `lw status` and clients
  reading an outdated client count or busy state until the next change. It
  now keeps retrying the update until it lands, and logs only when it keeps
  failing for several seconds. (#123)
- `lw daemon stop` no longer calls a daemon that is still starting (slow on a
  loaded machine) "not responding" after 3 s; it waits the same ~10 s as for
  a running daemon. (#123)
- Windows: lines written to `.nvim/loomworks.log` at the same moment by the
  editor and `lw` commands are no longer lost (one overwrote the other).
  (#123)
- Windows, workspace daemon: `lw build` run from cmd.exe, PowerShell or a
  Visual Studio developer prompt (anything started from a cmd.exe, such as a
  `.cmd` shim) now builds through the daemon; it used to fall back to an
  in-process build without a word, because the daemon refused the hidden
  `=C:` / `=ExitCode` entries of such an environment. (#118)
- Workspace daemon: a build the daemon does not run now always says why in
  one line (`lw: the workspace daemon declined the build (<reason>); running
  without it`, or `... could not take the build (<reason>) ...`); only
  `--no-daemon`, `LOOMWORKS_NO_DAEMON` and `CI` stay silent. (#118)
- Windows, workspace daemon: Ctrl-C (or Git Bash's `kill -INT`) now cancels a
  routed build even when `lw` was started with Ctrl-C disabled (`start /b`, a
  new process group); the build used to run to completion. (#118)
- Windows, workspace daemon: the daemon no longer fails to update its handle
  (`could not write the handle: EPERM`) while a client is reading it. (#118)
- `lw help daemon` no longer claims a paused reader (`lw build | less`) pauses
  the build tool at once: up to about 4 MiB of output is buffered first.
  (#118)
- Windows: MSVC builds, configures and `lw run` no longer print
  `'vswhere.exe' is not recognized as an internal or external command` after
  `==> [build]` / `==> [configure]`. loomworks now puts the Visual Studio
  Installer folder (where `vswhere.exe` lives) on the PATH of every
  vcvarsall run, when it exists and is not already there. (#119)
- Linux/macOS: a build, configure, clean or test step killed by a signal
  (the out-of-memory killer, `kill -9` on the build tool) no longer counts as
  a success. `lw build` used to record the step as built and print `BUILD OK`;
  it now fails with exit status 128 + the signal (137 for SIGKILL) and says
  `killed by signal 9 (SIGKILL)`, with or without the workspace daemon. `lw
  run` and `lw test` report such a program with the same status. (#117)
- A build step whose program cannot be started now says why (`lw: cannot
  start <program>: <reason>`), the same with or without the workspace
  daemon. (#117)
- `lw build --target` accepts a target exactly as `lw target` lists it,
  `<project>:<target>`, and builds it in that project only (the build tool
  used to get the qualified name and fail with `ninja: error: unknown
  target`). A bare name that one project lists builds in that project only;
  one that several projects list is refused, naming the `<project>:<target>`
  choices. Any other name (`install`, a custom target) still goes to the
  build tool as before, and a failure names close matches as
  `<project>:<target>`. The same applies through the workspace daemon. (#116)
- Workspace daemon (experimental, `runtime-mode daemon`): a routed
  `lw build` whose output is not being read (`lw build | less`, paused) no
  longer makes the daemon hold the whole build output in memory; the build
  tool waits until the output is read, as without the daemon, and Ctrl-C
  still stops it. Other connected clients get at most 4 MB of a build's
  output, and one that falls far behind is disconnected. (#115)
- Workspace daemon: `lw build` from another terminal tab, pane or SSH session
  no longer reloads the daemon's workspace, or builds without the daemon
  while another build runs, just because variables naming the terminal or
  session differ (`WT_SESSION`, `TMUX_PANE`, `SSH_TTY`, `VSCODE_*`, ...); the
  build still gets them. Ctrl-C of a routed build no longer stalls the
  daemon while the build tool is stopped, and a build tool that survives the
  process-tree kill is killed directly. On Windows, the daemon's own lookups
  for a build from an editor-hosted client never run a program from the
  current directory. A development daemon run from a source directory
  (`luvi <dir>`) is replaced after a source edit. (#115)
- `lw daemon stop` (and `restart`) no longer reports a healthy but slow
  workspace daemon as "not responding" on a loaded machine: the stop request
  may use the whole stop wait (about 10 s) instead of giving up after 2 s, and
  is sent again if it fails early. A hung daemon is still reported after the
  same wait. `lw daemon status` waits up to 5 s for the daemon's answer. (#111)
- `lw nuke` refused while a build runs (or another workspace operation holds
  the workspace) now prints only the refusal, as one line
  (`lw: cannot nuke: a build is running in ... (pid N) - wait for it, or stop
  it (lw nuke --break-locks)`): it no longer lists the paths it "will delete"
  first, nor wraps the message in `nuke failed:` / `loomworks:`. The locks are
  checked before the list and the prompt; the editor's nuke checks them before
  its confirmation dialog, and `lw trust --discard` before its notice. (#114)
- The `lw status` / `lw daemon status` hint for a stale daemon handle said
  `lw daemon stop` was needed; any workspace command in daemon mode recovers it
  by itself, and the hint now says so. `lw help daemon` lists the minute form
  of `daemon-idle-timeout` (90s, 2m, 30m, 1h). (#109)
- On macOS and Linux, a workspace daemon started from one environment (a
  desktop terminal) is now usable from another (ssh, cron, `sudo -u`, a
  container shell) whose `TMPDIR` / `XDG_RUNTIME_DIR` differ, instead of being
  refused as an "untrusted handle". The socket is accepted wherever it is when
  it is the workspace's own socket, owned by you, in a private (0700) directory
  owned by you. (#108)
- On Windows, saving a file no longer fails when a leftover temporary file is
  briefly held open by an antivirus scanner or indexer: the save retries for a
  moment. (#108)
- `--break-locks` and `lw daemon stop --force` recognise an lw holder more
  strictly: a `luvi` process counts only when it runs the loomworks app, and an
  `lw-*` binary only when it is a release download (`lw-linux-x86_64`, ...) or a
  pinned copy (`lw-<version>-<asset>`). (#108)
- Read-only commands (`lw status`, `lw profile list`, `lw export`,
  `lw import --dry-run`, `lw health`, ...) and the editor no longer rewrite a
  build cache written by an earlier loomworks (unsigned) when they load the
  workspace: it is ignored in memory and replaced only by the next command
  that writes the cache. (#104)
- The `lw import` summary printed the active profile twice; it now appears
  once, under the table. (#104)
- The `lw import` summary now lists everything the import resets: each intent
  change, whether the active profile is kept, and the device selections and
  fill values dropped with removed profiles. It warned that the next
  `lw publish` would remove items from `loomworks.json` when there was no
  `loomworks.json` (and labelled it `--local` without that option); the warning
  now appears only when the file exists and items would really be removed,
  and names them. (#102)
- When no profile was active before an import, the `lw import` summary said
  nothing about it and the closing "no active profile" hint read as if the
  import had cleared one. The summary now says `active profile: none
  (unchanged)` and the hint says none was active before. (#103)
- A publish, rename, import or profile removal that is killed half-way no
  longer leaves `loomworks.json`, the working copy and the build cache
  disagreeing: the files are committed together through a journal, and the
  next command completes an interrupted commit (or, if a file was changed
  since, refuses the workspace until `lw unlock --journal`). (#101)
- `lw nuke` (and the editor's nuke) no longer deletes a build directory while
  a build runs in it: it takes every build directory's lock first and refuses
  naming the build. The editor's delete and reset take the build-directory
  locks too, so they refuse while a CLI build uses the directory. (#100)
- A build recorded by `lw build` while the editor was open could be lost: the
  editor's next save of the build cache overwrote it. Saves now merge with the
  cache on disk, keeping the other process's build records. (#94)
- A configuration, profile or project change made with `lw` while the editor
  was open could be silently undone by the editor's next save of the working
  copy (and the other way round). (#94)
- A build cache or working copy written by a newer loomworks was read as
  empty by an older one when it changed while loaded, and the next save
  dropped its contents. (#94)
- `lw publish`'s "loomworks.json is empty" note now judges exactly what was
  written. (#93)
- Outside a workspace, a mistyped command or option reported "no
  loomworks.json found" instead of the typo. (#90)
- `lw profile remove` pointed at `lw clean`, which cannot reach a removed
  profile's build directories; it now names `lw reset --all`. (#90)
- The `lw help` quickstart called `profile create`'s operand `<name>`; it is
  the configuration set. `lw config` with an unknown sub-command now lists
  `describe` too. (#90)
- `lw status --check` outside a workspace exited 0, so a misconfigured CI gate
  passed silently; it now exits 1 (same page as plain `lw status`) (#92)
- A project whose module is not installed, or is refused for an interface
  version mismatch, lost its `configurations` on `lw publish` and whenever the
  working copy was saved. They are now kept unchanged, and load normally once
  the module is available. (#95)
- When git took longer than 1.5 s to answer, `lw status` and `lw health` said
  "git unavailable" outside a workspace and, inside a git worktree, silently
  dropped the `lw pull` offer. They now say git timed out and point at
  `lw worktree` (or `lw pull`), which wait longer; `lw worktree`, `lw worktree
  add` and `lw pull` likewise report a git that does not answer within 30 s as
  a timeout, not as "git is not available" or "not in a git repository". (#98)
- Experimental daemon: a build running in the workspace daemon now reports
  its percent from the build tool's progress lines (`[N/M]` for ninja), as an
  editor build does. It moved only between configure and build steps, so
  `lw status`, the editor's progress and a late-joining editor showed 0% for
  the whole of an already configured build. (#136)
- The test explorer shows the tests of every project in the active profile
  again; when every project's tests were already discovered it showed only
  the first project's tests. (#221)
- `lw test`: a disabled gtest test (`DISABLED_`) is no longer counted as
  passed, and skipped (`GTEST_SKIP`) and disabled tests are counted apart
  from passed ones, both in a test executable's result line and in the saved
  test targets' summary, e.g. `1009 tests passed, 2 skipped, 1 disabled`.
  (#227)
- Test results: a failure, skip or error inside a testcase written on a
  single line of the results XML is no longer counted as passed. (#227)
- Status page: the header shows the running loomworks version (e.g.
  `0.1.44`, or `0.1.44+dev` in a source checkout) instead of a stale
  `0.0.1-dev`. (#236)
- A failed `lw test` step now keeps its counts in the summary, e.g.
  `FAILED (exit status 1, 1 failed test, 364 passed, 2 skipped)`, in the step line
  and the per-profile summary, on a host or a device. Before, only the failure
  reasons were shown. A step without per-case results keeps its line. (#241)

### Removed
- `lw update`, deprecated since 0.1.37. Use `lw bootstrap upgrade` (or
  `lw bootstrap install --version <x.y.z>`) to move a repository's pin, and
  `lw self-update` to update lw itself; `lw update` now only names these and
  exits 2. (#89)

## 0.1.42 - 2026-09-30

A small polish release: after an update, the list of what changed is the last
thing `lw self-update` prints.

### Changed
- `lw self-update` prints its "what's new" lines last, after the host-binary
  line. (#87)

## 0.1.41 - 2026-09-30

Release notes are now built in: `lw release-notes` shows what changed, offline,
and `lw self-update` tells you what is new after an update.

### Added
- `lw release-notes` prints what changed in each release, offline, from the
  release you run: the three newest by default, `--since <version>`, `--all`,
  `-n <N>`, one `<version>`, or `--json`.
- After `lw self-update` installs a newer release, it lists what changed since
  your previous version. The first interactive run after an update that did not
  show this prints a one-line pointer to the notes instead. Silence both with
  `lw settings set release-notes off` or `LOOMWORKS_RELEASE_NOTES=off`.
- `lw bootstrap upgrade` names the command that shows what changed between the
  old and the new pinned release.

## 0.1.40 - 2026-09-30

`lw health` now focuses on what your workspace uses, launch configurations can
be described and renamed, and a mistyped option is an error instead of being
ignored.

### Upgrade notes
- `lw health` without arguments now reports only what the current workspace
  uses; run `lw health --all` for the full report you got before. (#79)
- A command given an option it does not know now exits with status 2 instead of
  ignoring it. Arguments for the program or build tool belong after `--`. (#83)
- `lw run --dry-run` no longer builds; use `--print` to build first and then
  print the command. (#85)

### Added
- `lw health` scope and areas: plain `lw health` checks only the tools, SDKs and
  editor tools the workspace uses (over every profile), `--all` checks
  everything with the relevant items marked, and area names narrow a run
  (`lw health toolchains cache`). (#79)
- Launch configurations take an optional description (`lw launch describe`,
  `lw launch add --description`), shown in `lw launch list` and `lw target`;
  `lw launch rename` (alias `mv`) renames one and updates every profile that
  uses it as its default target. (#78)
- `lw self-update --channel <name>` saves the channel for later runs, like
  `lw settings set channel <name>`; `lw version` marks a prerelease bundle.
  Saving needs this release's lw binary: from an older binary, select the
  channel once more after the update. (#84)

### Fixed
- An unknown option is a usage error that names it and points at
  `lw help <command>`; a mistyped option can no longer fall through to a build
  or a launch. (#83)
- `lw run --dry-run` changes nothing: no build, no deploy, no execution; it
  prints the resolved command like `--print`. (#85)
- Saving from an editor dialog keeps every field the dialog does not edit
  (configuration env and compiler-family overrides, a launch's device block, a
  configuration set's description on rename). (#75)
- `lw status` and `lw configset list` cut long lists at whole names and fit
  narrow terminals. (#74)
- Ctrl-C through `lw.cmd` no longer leaves cmd.exe asking "Terminate batch job
  (Y/N)?", and the pin redirect waits for the pinned lw to finish its cleanup.
  Refresh the launcher with `lw bootstrap install`. (#76)
- `lw worktree` and `lw pull` wait for a slow git instead of reporting that git
  is missing. (#80)
- Creating a build directory tolerates another process creating the same
  directory at the same time. (#81)
- Test-suite flakes on Windows CI. (#77)

## 0.1.39 - 2026-09-30

Projects, configurations, configuration sets and profiles can carry git-style
descriptions; device runs clean up after interrupts.

### Added
- Optional descriptions for projects, configurations, configuration sets and
  profiles: the first line is shown as a summary in lists, the rest in detail
  views. Set them with `lw <project|config|configset|profile> describe` or `-m`
  when creating, or from the editor. (#72)

### Fixed
- Ctrl-Break, closing the console and hangup stop a device program like Ctrl-C
  does, and a later run reaps a device program left behind by a hard-killed or
  disconnected run. (#69)
- A configuration rename keeps every declared field (variables, languages,
  compiler-family overrides). (#70)

### Security
- Workspace names can no longer inject items into the lualine / winbar
  component. (#71)

## 0.1.38 - 2026-09-29

New release bundles keep working on older lw binaries.

### Fixed
- Bundle-routed commands failed with "module 'boot.help' not found" on lw
  binaries older than 0.1.34 after `lw self-update`; they work again on every
  binary back to 0.1.2, and CI checks each release against old binaries. `lw
  health` says when your lw binary predates self-update and needs one manual
  reinstall. (#68)

## 0.1.37 - 2026-09-29

`lw bootstrap` becomes a status page, with `install` and `upgrade` to write and
bump a repository's pin.

### Upgrade notes
- `lw update` is deprecated: use `lw bootstrap install --version <x.y.z>` or
  `lw bootstrap upgrade`. (#67)

### Added
- `lw bootstrap` shows the pin, the launchers and the repository metadata
  without writing anything; `lw bootstrap install` converges a repository to a
  correct pin and launchers; `--pin-only` pins without launchers;
  `lw bootstrap upgrade` pins the newest release. (#67)

## 0.1.36 - 2026-09-29

Polish for repository launchers and pins.

### Added
- `lw health` checks the repository launcher and pin (hashes, launcher
  generation, line endings, ignore rules, stale cached binaries). (#66)
- `lw bootstrap` maintains `.gitignore`, `.gitattributes` and the executable
  bit of `lw.sh`, and launchers retry interrupted downloads. (#66)

### Fixed
- An lw built from source verifies official releases: the production release
  key is embedded in the source. (#66)

## 0.1.35 - 2026-09-28

Launcher and test-run fixes.

### Fixed
- `lw.cmd` calls Windows system tools by absolute path, so Git Bash's `find` on
  PATH no longer breaks downloads. (#64)
- `lw test` on a fresh clone no longer runs a full build before a test runner
  that rebuilds its own targets. (#63)

## 0.1.34 - 2026-09-28

Run and test cross-built programs on devices, and workspace trust.

### Added
- Run and test cross-built programs on a device (`lw device`, `lw run` and
  `lw test` on device targets), through SDK-provided runners. (#62)
- Workspace trust: lw signs the `.nvim` state it writes on this machine and
  asks before using a working copy it did not sign (`lw trust`, `lw nuke`). (#58)

## 0.1.33 - 2026-09-28

Git submodule support and build argument forwarding.

### Added
- `lw health` reports git submodule drift: checked-out versus recorded commit,
  recorded commit versus the tracked branch, uninitialized nested
  submodules. (#61)
- `lw build <profile> --target <name>` builds one target (repeatable). (#59)

### Fixed
- lw and the editor find the superproject's workspace from inside a git
  submodule. (#60)
- `lw build -- <args>` passes the arguments to the native build command,
  including MSVC builds wrapped in vcvars. (#59)

## 0.1.32 - 2026-09-27

Hardening against untrusted repository files.

### Security
- Repository files can no longer reach module loading or process creation:
  plugins load only from the runtime path, bare program names resolve to
  absolute PATH entries, pinned bundles and binaries are provisioned by hash
  into the per-user data directory, and terminal control characters in data
  are escaped. (#57)

## 0.1.31 - 2026-09-27

`lw health` becomes a full "is this machine ready?" check.

### Added
- `lw health` lists every tool loomworks knows (build tools, compilers,
  compiler caches, language servers, debug adapters, SDKs, plugins, lw itself),
  found or missing, and which of them the workspace requires; `--verbose` and
  `--json`. (#56)

### Fixed
- `lw install` replaces a running lw instead of writing over it. (#55)

## 0.1.30 - 2026-09-25

Fixes from real-project testing of 0.1.29.

### Added
- `lw profile select <name>` works without a terminal, and `--none` clears the
  active profile. (#54)

### Changed
- Non-interactive `build`, `test`, `run`, `clean` and `reset` never infer a
  profile; name it explicitly (`lw profile query` helps scripts pick one). (#54)

### Fixed
- MSVC /Zi compatibility findings follow CMake re-runs; CMake presets are
  filtered by host condition; configuration values are validated. (#54)

## 0.1.29 - 2026-09-24

Compiler caching, `lw health`, and a self-update that also updates the lw
binary.

### Added
- Compiler caching with ccache or sccache for cmake and meson (`cache` policy:
  auto, ccache, sccache, off); `lw help cache`. (#49)
- `lw health` lists suggestions for the workspace and this machine. (#49)
- A configuration `env` field, with inheritance. (#49)
- `lw self-update` also replaces the lw binary with the same release's, after
  verifying it against the signed hash list; `lw version` reports the binary's
  release. (#52)
- `lw build --reconfigure`, and every configure says why it runs. (#49)

### Fixed
- A reconfigure applies every configure-input change. (#49)
- `lw <command> --help` shows help instead of running the command. (#52)
- On Windows, a `lua/` directory beside `lw.exe` can no longer shadow lw's own
  boot modules. (#53)
