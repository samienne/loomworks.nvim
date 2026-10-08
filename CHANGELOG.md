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

### Upgrade notes
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
  never start it; it exits after `daemon-idle-timeout` (default 1h) without
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

### Changed
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

### Fixed
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
