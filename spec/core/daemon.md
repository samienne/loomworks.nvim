> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.
>
> **Target design, implemented in steps.** This section specifies the end state
> of the workspace runtime and the order in which it is reached. It does not
> claim behaviour master has: every subsection carries a **status** line, and
> only parts marked *master* are in effect. The rationale, the superseded
> decisions and the step plan live in [`../../DAEMON.md`](../../DAEMON.md).
>
> Status legend: **master** — in effect; **#88** — implemented on the
> experimental daemon branch (draft PR #88), to be carried over; **re-cut** —
> exists on #88 but must change to match this section; **future** — not
> implemented anywhere.

## 19. Workspace Runtime and Daemon

**End state.** Each workspace has **exactly one runtime**: a single process
that owns the workspace model, its `.nvim/` files and the operations that
change them. Every operation of §1–§18 executes in that runtime; the
non-interactive host and the editor are **clients** of it. The runtime is the
host binary itself, run in **daemon mode** (`lw daemon run`) — there is no
separate daemon program, and one implementation of every operation, reached
through one protocol, whether the runtime is a background process or runs
inside the client (§19.1).

**Transition.** Until every operation has moved into the runtime, hosts still
load the workspace and execute operations themselves (the **in-process
path**, §1–§18 as written). The in-process path, an attached run and a daemon
coexist safely because all of them take the same **operation locks** (§19.3)
and commit multi-file changes the same way (§19.4). §19.19 lists the order.

### 19.1 Runtime modes

*Status: master for the transition values — the host setting `runtime-mode`
(`in-process` | `daemon`), `LOOMWORKS_RUNTIME`, the editor option
`runtime.mode` (the editor observes the daemon in `daemon` mode, §19.16) — and the selection of
attached by `--no-daemon`, `LOOMWORKS_NO_DAEMON` and `CI`
(`daemon/runtime.lua`), and the editor's selection with lw's `runtime-mode`
setting and the source on its Runtime line (`runtime.editor_select`,
`observer.runtime_line`); the loopback transport and the attached server
(`daemon/loopback.lua`, `Server:start_attached` / `Server:adopt`,
`client.loopback_session`, `command.start_attached`) and the CLI's attached
routing of step 5e (`cli._attached_selected`, `cli._delegate_attached`)
implemented; the end-state values future.*

A command runs its operation in one of two ways:

- **Shared** — the client finds the workspace's daemon (§19.6) or launches one
  (§19.10), sends the request, renders the reply and streamed output, and
  exits. The daemon keeps running (§19.11).
- **Attached** (`--no-daemon`) — the client process runs the daemon code
  itself, over an in-memory **loopback transport** that carries the same
  messages through the same encoder/decoder and handlers as the pipe (§19.8),
  minus endpoint and authentication. Nothing keeps running after the command.

Attached is selected, in this precedence: the `--no-daemon` flag; the
environment variable `LOOMWORKS_NO_DAEMON` (`1` selects attached, `0` selects
shared even in CI); `CI=true` in the environment; the host setting
`runtime-mode` (`no-daemon`); and, at run time, a failed background launch
(§19.10) — also the launch step itself failing with an error. Otherwise the command runs shared. An invalid configured value is
reported and ignored (falls through to the next source).

The editor selects its mode in this precedence: the environment
(`LOOMWORKS_RUNTIME`, then `LOOMWORKS_NO_DAEMON` and `CI` as above); its setup
option `runtime.mode`; lw's own setting `runtime-mode`, read from the per-user
settings file `lw settings` writes (§16.40, `<config>/config.json`); and the
`in-process` default. The editor reads that file on each workspace load, never
writes it, and treats a missing file or key as absent; an unreadable file or an
invalid value is the observer's note (§19.16) and falls through to the default.
`no-daemon` selects `in-process` in the editor. The status page's Runtime line
names the source that decided (spec/ui.md §1.1). The editor runs attached
inside its own process when it has no host binary (§19.16).

**During the transition** the setting `runtime-mode` takes `in-process` (the
default) or `daemon`, with `LOOMWORKS_RUNTIME` as the environment override. In
`in-process` mode no daemon is launched or used. In `daemon` mode every
workspace command ensures the daemon is running (launching it if absent)
— except read-only commands (§19.14), which never launch, stop or restart a
daemon; they use a live compatible one or read in-process — and routes the
operations that have moved (§19.19); all other operations run on the
in-process path. When the default flips, `in-process` is accepted as a
synonym of `no-daemon`.

**Loopback during the transition (§19.19 step 5e).** In `daemon` mode, an
attached selection — `--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI=true`, the
`no-daemon` setting, or a failed background launch — runs the routed
operations (`lw build`, `lw test`, the preparation of `lw run`, `lw clean`,
`lw reset`; §19.15) attached: the client starts the daemon's server and build
service in its own process, holds the runtime lock in `attached` mode for the
command (§19.2), and sends the same request over the loopback transport. The
read-only commands (`lw status`, `lw profile show` / `query`, the read form of
`describe`, `project` / `config` / `configset` / `launch` list and show,
`config get`, `lw tools`; §19.13, §19.14) read the projection of a live
shared daemon when one is compatible (it authenticates and runs this lw's
version), and otherwise read in-process; never through the loopback. A read
never launches, stops or restarts a daemon and never takes the runtime lock;
a daemon that does not answer in time (a bounded wait, unanswered keepalive
pings) is left alone and the command reads in-process after a one-line note.
The
operations not yet routed (profile and project mutations, publish / import /
pull, devices — they need the command machinery of §19.14) and every
operation in `in-process` mode (still the default) run on the in-process path
and take no runtime lock. Three rules differ from a shared run:

- An attached `lw run` releases the runtime lock when its preparation task
  ends, not while the program runs (the program is the client's, §19.15 Run).
- `--break-locks` given with an attached selection runs attached too: its
  ask-and-kill recovery stays with the client process, which is the runtime.
  (When a live daemon holds the runtime lock, no attached runtime starts: the
  operation keeps its in-process path and its one `--break-locks` line,
  §19.15. In a shared selection `--break-locks` keeps its in-process path
  beside the daemon, as before step 5e.)
- An attached operation prints no `… through the workspace daemon (pid N)`
  line (§19.15): no daemon is involved.

The editor runs no loopback runtime during the transition (§19.16); its
attached mode arrives with the thin-client step (§19.19 step 5).

### 19.2 One runtime per workspace: the runtime lock

*Status: master for daemons (`daemon/rlock.lua`, the §19.5 record plus
`mode`, `command`, `host_version`; held by `daemon/server.lua` for its
lifetime, a held lock makes `lw daemon run` exit with status 3, a replaced
record makes the daemon exit 1); the attached runtime's side
(`Server:start_attached`: R in `attached` mode with the command, released on
stop without ending the process), its use by the CLI and the busy wait
(`cli._delegate_attached`, setting `runtime-busy-wait`) implemented.*

The **runtime lock** `<root>/.nvim/loomworks.daemon.lock` designates the one
runtime of a workspace. It uses the build-directory lock primitive (§16.6): an
exclusive create and an mtime heartbeat (about 5 s); a dead or hung holder is
handled per §19.5. Its record is the common lock record of §19.5 plus the mode
(`daemon` or `attached`), for an attached run the command, and the host
version.

- A **daemon** acquires it before binding its endpoint and holds it for its
  lifetime. A daemon whose start finds the lock held by a live holder exits
  without side effects (the launching client then connects to the holder).
- An **attached** run acquires it for the duration of its command. If a live
  daemon holds it, the attached run does not start a runtime of its own: it
  connects to that daemon as a shared client (§19.1 decides only that nothing
  is *launched*), after the same version handshake as any client (§19.9): a
  busy daemon of another version makes the command a version-bypass run, and
  an idle one is stopped, but nothing is launched in its place — the command
  then runs attached. If another attached run holds it, the client waits briefly
  (setting `runtime-busy-wait`: `0`, seconds, or a number with `ms`, `s` or
  `m`; default 5 s) and then fails cleanly:

  ```
  lw: workspace busy: lw build (pid 4242 on HOST) is running here without a daemon — retry when it finishes
  ```

  Exit status 1. Never a second writer. Parallel jobs that must not wait for
  each other use separate checkouts. A hung daemon holder is reported as hung,
  not busy (§19.5). An attached holder whose process exists is reported busy
  even when its heartbeat is stale: a confirmation prompt (`lw reset`) blocks
  its event loop. Like any hung holder it is never reclaimed automatically,
  and `lw daemon stop` refuses it (no daemon).
- A **shared** selection (a routed operation in `daemon` mode) that finds the
  lock held by an attached run waits for it the same `runtime-busy-wait`, then
  fails with the same `workspace busy` line, exit status 1; when the attached
  run ends in time, the client launches or uses the daemon as usual. It never
  runs the operation beside the attached runtime.
- A holder that finds its lock record replaced (its lock was reclaimed while it
  was suspended) has lost authority: it stops at once, writes no workspace
  file, and exits nonzero. From the moment it notices, its workspace saves
  neither the cache nor the working copy — also a clean's wipe or a reset's
  deletion still stopping between entries (what such a deletion wrote before
  it started, its entries `unknown`, stays for the next runtime) — and no
  request not yet accepted starts. An attached run first cancels its running
  operation as Ctrl-C does (its steps' process trees killed), then ends the
  command with exit status 1 (`lw: the workspace runtime lock was taken over
  during the <op> — stopped`; for a root removed meanwhile, §19.11, `lw: the
  workspace root was removed during the <op> — stopped`). It never falls back
  to the in-process path — also not after a `lw reset` confirmation it was
  waiting on: nothing is reset.
- A holder on another host (shared or network drive) is respected while its
  heartbeat is fresh; it cannot be connected to or stopped from here (§19.11).

The in-process path (transition) does not take the runtime lock; it is
serialized against the runtime by the operation locks (§19.3). The single
exception after the transition is a **version-bypass run** (§19.9).

### 19.3 Operation locks

*Status: master — build-directory locks (§16.6), device locks (§18.7),
per-file save locks (§2.7) and the workspace operation lock, all with the
§19.5 record; the lock order R → O → B → D → F (R does not exist yet, §19.2);
`lw nuke` and the editor's deletions taking build locks. This is step 1 of
§19.19 and comes before any lifetime work.*

Every **mutating operation**, on any path (in-process, attached, daemon),
acquires **all** the locks it needs **before its first side effect**, in the
order below. If any lock cannot be acquired, it releases what it took and
refuses, naming the holder; nothing has been changed. Once it holds its locks
it either completes or leaves the state defined by §19.4 — never a mix of two
operations' effects. A daemon takes exactly the same locks as the in-process
path, so during the transition the two paths interoperate, and after it the
locks still guard against older versions and version-bypass runs (§19.9).

**Lock classes, outermost first:**

| # | Lock | Scope / file | Held | Acquisition |
|--|--|--|--|--|
| R | Runtime | `.nvim/loomworks.daemon.lock` (§19.2) | daemon lifetime / attached command | brief wait, then fail |
| O | Workspace operation | `.nvim/loomworks.op.lock` | one multi-file operation | fail-fast |
| B | Build directory | `<build dir>.loomworks-lock` (§16.6) | one build-directory operation | fail-fast |
| D | Device | per-serial, per-user (§18.7) | one remote operation | waits by default (§18.7) |
| F | File save | `<file>.lock` (§2.7) | the re-read + write, milliseconds | bounded retry (about 2 s) |

**Order.** A process acquires locks only in the order R → O → B → D → F, and
within a class in a canonical order: build directories by normalized identity
(§4.6 resolved real path, §2.3 normalization), devices by serial, files in the order
`loomworks.json`, `loomworks.user.json`, `loomworks.cache.json`. It never
acquires a lock of an earlier class, or an earlier member of the same class,
while holding a later one. Release order is free. Waiting (R briefly, D by
default, F bounded) is allowed only because it respects this order, so no
cycle — and no deadlock — is possible among compliant processes. An operation
that needs a lock it did not take up front (for example a remote run that
discovers it must rebuild) first releases every lock of a later class.

The **workspace operation lock** O is the O_EXCL + heartbeat primitive with the
common lock record of §19.5 (`{ pid, host, start_time, lock_nonce, kind,
operation, started_at }`). It is taken by every
operation that writes more than one of the three workspace files, or that
removes a workspace file or a build tree as part of a larger change:

- publish and per-item publish (§2.4: published snapshot + working copy);
- import (§16.39) and working-copy pull (§16.25);
- renames that propagate into the cache (project, configuration, set, profile);
- profile / configuration deletion that removes build directories;
- reset, single-profile and all-scope (§16.30);
- nuke (`lw nuke`, the editor's nuke) — which additionally takes the **build
  lock of every build directory** it will remove, so it refuses while any build
  runs instead of deleting under it;
- `lw trust --discard` (§17.10).

Single-file working-copy mutations (profile select, project add, …) and a
build's cache write-back do not take O; the per-file stale-save guard (§2.7)
serializes them against a concurrent O holder, because the O holder's commit
re-checks every file under its F locks (§19.4) and refuses on a stale working
copy.

A refused acquisition is reported with the holder:

```
lw: workspace busy: publish (pid 4242 on HOST, 3s) — retry when it finishes
lw: cannot nuke: a build is running in build/debug (pid 4242) — wait for it, or stop it
```

The CLI exits 1 (the build-directory lock's existing exit codes are
unchanged); the editor shows an error notification. The refusal is one line
with one prefix. Nuke and `lw trust --discard` take (or check) their locks
**before** they list what they would delete or ask for confirmation, so a
refused one prints only its refusal: with `-y` / `--yes` the locks are held
from then until the deletion ends; a confirmation (the CLI prompt, the
editor's dialog) only checks them — taken and released, never breaking a
holder — and the locks are taken again once confirmed (`--break-locks` acts
then). The editor's check passes over its own builds, which its nuke stops
before taking the locks. `lw unlock --workspace`
(and `lw unlock --all`, §16.6) also clears an O lock whose holder is gone, and
`--force` one whose holder runs; dead and hung holders of every class are
handled by §19.5 (`--break-locks`, accepted by every command above).

O is re-entrant within one process: an operation that holds it (`lw reset`,
in the CLI or in the workspace daemon, which takes O and then every build lock
before the workspace's deletion runs) may call another operation that takes it; the lockfile goes
with the outermost holder. Likewise a deletion skips the build locks its own
process already holds.

**Which build locks nuke and deletions take.** A deletion (profile delete or
reset, orphan delete, `lw reset`) takes the build lock of every build
directory its plan removes, after O, as a counted reference within its
process: an editor task on the same directory that the deletion cancels
releases only its own reference, so the lock stays until the removal ends.
`lw nuke` removes the whole `.nvim/build/`; it takes the lock of every
directory under it that has a lockfile (`<dir>.loomworks-lock`, found by a
depth-bounded, link-free scan — a lockfile marks a directory some process uses
or used) and of every build directory of the loaded workspace there. Holding
them, it removes the build and health caches first (so nothing claims a
configured or built tree from then on), then renames `.nvim/build` to
`.nvim/build.nuke-<hex>` in one step and removes that tree, keeping its event
loop running so O keeps heartbeating. A build that starts once the locks are
gone creates a fresh `.nvim/build`, never a directory inside the tree being
removed. A tree left aside by a nuke that crashed (a real directory directly
in `.nvim/` named exactly `build.nuke-<hex>`) is removed by the next nuke.
Where the rename is impossible (a file in the tree held open on Windows), nuke
refuses after removing the caches, leaving the tree: removing it in place
would let a build that starts once the locks go write into a tree being
deleted. The editor's nuke first stops its own tasks and unloads its
workspace (which then writes nothing), so its own build neither keeps writing
into the tree nor recreates the cache; the operation lock is held until the
removal has really ended.

A build lock that a task of the same process already holds is taken by a
deletion as a counted reference, not acquired again, so the editor's deletion
— which takes O while its own task may hold the directory's build lock — never
waits on itself and cannot deadlock (every cross-process acquisition is
fail-fast). `Workspace:teardown` lets an in-flight deletion finish (bounded)
before it releases that deletion's locks.

### 19.4 Crash-consistent multi-file commits

*Status: master (step 1 of §19.19).*

A multi-file operation commits its file changes with a **journal**, so that a
crash at any point leaves either the old state, the new state, or a marked
state every compliant reader completes to the new state before using the
workspace.

**Commit**, holding O and the F locks of every file involved (in order):

1. **Check.** Re-read each file and apply the stale-save rules of §2.7: a stale
   working copy refuses the whole operation (nothing written); a stale cache is
   merged first.
2. **Stage.** Write each new file content to `<file>.txn-<id>` beside the
   target and flush it to stable storage. A removal has no staged file. The
   staged bytes are final — signed where the file is signed (§17.3).
3. **Commit point.** Atomically write the journal
   `<root>/.nvim/loomworks.txn.json`: `{ id, operation, pid, host, written_by,
   entries: [ { file, action = replace|remove, sha256_new?, sha256_old? } ] }`,
   entries in the file order of §19.3.
4. **Apply.** For each entry in order, rename the staged file over the target
   (or remove the target), then flush the directory where the platform
   supports it.
5. **Finish.** Remove the journal, then release the locks.

| Crash during | On disk | After recovery |
|--|--|--|
| 1–2 | old files + stray `*.txn-*` | old (stray files removed) |
| 3 (journal write) | old files; journal absent or its temp | old |
| 4 | some targets new, some old; journal present | new |
| 5 | new files; journal present | new (journal removed) |

**Recovery.** A process that loads the workspace, or acquires O, and finds a
journal first checks O: while the journal's writer still holds a live O lock (§19.5)
the commit is in progress, and the reader waits for it (bounded, as for F) or
reports the workspace busy. Otherwise, holding O, it **rolls forward**: per
entry, a target whose hash already equals `sha256_new` (or an absent target
for a removal) is done; a staged file whose hash equals `sha256_new` is renamed
over the target; a removal removes a target whose hash equals `sha256_old`. It
then removes the journal and stray staged files and reports once:

```
lw: completed an interrupted publish (pid 4242 crashed) — .nvim/loomworks.user.json, .nvim/loomworks.cache.json
```

An entry whose target matches neither hash (another writer that ignores
journals changed it) or whose staged file is missing is left untouched; the
workspace is then **refused** (as a §15 invariant 11 refusal) with the journal
named and the remedy to discard it (`lw unlock --journal`). Nuke is not a
remedy: it acquires O, which completes or refuses the journal first, and it
resets only build state — the journal also covers `loomworks.json` and the
working copy.

**Validation.** A journal is data from disk: it is honoured only when every
entry names one of the three workspace files in `.nvim/` and the staged files
match `<file>.txn-<hex id>` beside them; anything else refuses the workspace
as above. Rolling forward never bypasses trust — the renamed files are verified
on load as any file is (§17.4).

**Implementation notes (master).** The operations that hold O commit through a
transaction: every write of one of the three files during it is staged (and
reads of a staged file in that process see the staged bytes), and the
transaction commits when the operation returns. The F locks of all three
files are held from the transaction's start to its end (they are held for
milliseconds: the operations are synchronous). A commit that touched one file
needs no journal — the rename is the commit point. Before the commit point the
holder checks that the O lockfile still carries its own record (fencing): a
holder whose O was reclaimed while it was suspended, or removed with
`lw unlock --force`, has lost authority — its staged files are removed and
nothing is written. An operation that reports failure commits none of its
staged writes, and a deletion whose working-copy / cache commit fails removes
no build tree. An ordinary save's
`.bak` copy is kept: step 4 renames the target to `<file>.bak` before renaming
the staged file over it, so a crash between the two leaves the target absent,
which recovery completes like a target with the old content. Recovery runs
when a process loads the workspace (the editor and every `lw` command) and
whenever a process acquires O; stray staged files (`<file>.txn-<hex>`, regular
files beside the three targets, and the journal's `.tmp`) are removed only by
an O holder. `lw unlock --journal` takes O without completing the journal and
removes exactly the journal and those stray files.

**Build trees.** Removing build directories (nuke, reset, deletion) is not
journalled; it keeps the existing crash rule — cache entries are marked
`unknown`/deleting before the removal starts and removed only after it
succeeds (§5.7, §15 invariant 1) — and the cache change that follows is then
committed as above.

**Older versions** neither take O nor read the journal; one that reads a
workspace between a crash and the next recovery can see a partially applied
commit. This is the same class of residual race as §2.7 "Remaining race".

### 19.5 Recovery from dead and hung holders

*Status: master for build-directory, device and file-save locks (B, D, F): the
record, the classification, the state recovery, `--break-locks` and
`lw unlock --force`; the operation lock O (step 1 of §19.19); the runtime
lock R (`lw daemon stop --force` / `kill`, `daemon/command.lua`; in `daemon`
mode a workspace command given `--break-locks` recovers a hung daemon the same
way before relaunching it). Kills and forced unlocks are recorded in the
runtime log (§19.10).*

A crashed or killed process must never leave a workspace stuck, and a hung one
must be recoverable with one command. These rules apply uniformly to every lock
of §19.3 (R, O, B, D, F) and to the handle file and socket (§19.6–§19.7).

**Lock record.** Every lock record carries: process id, host name, the
holder's **process start time** (as reported by the operating system; it
distinguishes a reused process id), a random nonce, the holder kind (`lw`,
`daemon`, or `editor`), the operation, and a start timestamp; its modification
time is the heartbeat. As JSON: `{ pid, host, start_time, lock_nonce, kind,
operation, started_at }`, plus `action` (a copy of `operation` that older
versions read) and the class's own fields. The nonce is `lock_nonce`, not
`nonce`: device-lock records already use `nonce` for their running program
(§18.7). `start_time` is opaque and carries its method (`win:`, `linux:`,
`mac:`); a value written by a method the reader cannot use is judged by
heartbeat alone. It is a string, compared only for equality: `win:<creation
time>` (the process creation time in 100 ns units, decimal),
`linux:<boot id>:<start ticks>` (field 22 of `/proc/<pid>/stat`, with the
boot id) or `mac:<seconds>.<microseconds>` — so it may itself contain colons,
and a daemon's handle carries the same value as its runtime-lock record
(§19.6). A daemon **instance id** `<pid>:<start_time>` (§19.10 "Skip an
instance") is the decimal pid, a colon and that value verbatim; it is split
at its first colon. A holder that holds a build-directory lock across
several steps rewrites the record's operation when it moves from configure to
build, so recovery knows which step was interrupted. A record without a start time (written by an older
version) is judged by heartbeat alone. A lock file is created with its
record already in it: the record is written to a temporary file beside it
(`<lock file>.new.<nonce>`, a name no lock-file reader or scan matches) and
given the lock file's name by a hard link, an atomic create-if-absent; the
temporary name is then removed. Where the file system has no hard links, the
lock file is created exclusively and its record written right after. A
holder rewriting its record writes a temporary file and renames it over the
lock file; that the lock file still carries its nonce is checked right
before each rename, so a narrow window remains in which a lock file forced
off or reclaimed between the check and the rename is overwritten (no wider
than with the earlier in-place rewrite). A reader that
finds a fresh empty lock file (modified within the last 2 s; one created
without hard links, or by an older version) reads it again for up to 250 ms
before judging it, so a record being written is never taken for another
host's live holder; one still empty then is judged as a record without fields.

**Holder states.** A process that finds a lock held classifies the holder:

| Holder | Test | Handling |
|--|--|--|
| **dead** | same host, and no process with that id **and** start time exists | reclaimed at once, automatically |
| **live** | same host, process exists, heartbeat fresh — or other host, heartbeat fresh | busy: fail-fast / wait per §19.3 |
| **hung** | same host, process exists, heartbeat stale | **not** reclaimed; reported as hung with the recovery command |
| **stale foreign** | other host, heartbeat stale | reclaimed automatically (the host cannot be checked; heartbeat rule of §16.6) |

The heartbeat runs on the holder's event loop, so a blocked or suspended
process stops heartbeating; a hung holder is never reclaimed automatically,
because it can resume and write. This replaces, for same-host holders, the
unconditional stale-heartbeat reclaim of §16.6. Reports:

```
lw: build/debug is locked by a hung lw build (pid 4242, no heartbeat for 2m) — recover with: lw build --break-locks
lw: the workspace daemon (pid 4242) is not responding — recover with: lw daemon stop --force
```

Reclaiming is an atomic rename of the record, done only if the record still
carries the nonce the reclaimer observed. A daemon's handle and socket are
removed by whoever reclaims its runtime lock.

**`--break-locks`.** Every command that acquires a lock of class R, O, B or D
accepts `--break-locks` (and `--break-locks=now`). When an acquisition finds a
**hung** or a **live, responsive** same-host holder, the command recovers right
away instead of refusing — a live holder is asked first and killed if it has not
let go within the wait:

1. **Ask.** A daemon holder is sent `stop` (frozen control subset, §19.8, so it
   works across versions); a non-daemon `lw` holder is sent the interrupt it
   handles (§16.6) where the platform allows signalling it. Wait a bounded time
   (about 5 s). `--break-locks=now` skips this step.
2. **Kill** — only once the process the record names is verified to be such
   a holder: its command line (Windows: the process's command line; Linux:
   `/proc/<pid>/cmdline`; macOS: `KERN_PROCARGS2`) is an `lw` host — the `lw`
   binary, a release host under its download name (`lw-linux-x86_64`, …) or a
   pinned copy `lw-<version>-<asset>` (§16.24); `luvi` running the loomworks
   app (a source directory named `lua` or `lua-<version>`, which when given as
   an absolute path must hold `loomworks/cli.lua` — a `luvi` running any other
   app is not an `lw` host); or the nvim-hosted
   `nvim … -l …/loomworks/cli.lua` — and, for a daemon holder,
   `lw … daemon run` (for this workspace when it names one with `--root`).
   A record is data from a shared directory: one naming an unrelated process
   of the user is refused (the process is never signalled), as is a holder
   whose command line cannot be read; the remedy is to remove the record
   without stopping anything. Then kill the holder's process tree — the
   daemon's process group, or the holder and its enumerated descendants (on Windows a forced tree
   termination).
3. **Verify** that no process with the holder's id and start time remains;
   otherwise fail and name the process.
4. **Reclaim** each lock whose record still carries the observed nonce.
5. **Recover state.** Roll a journal forward per §19.4. For each build
   directory the killed holder held, by the step its lock record names:
   - **configure** — its units reset to `unconfigured` in the cache (the
     directory is kept), so the next build reconfigures (§5.1): a half-written
     configure cannot be trusted;
   - **build** (configure had completed) — its units are marked not built
     (`configured`); the configure record is kept and the build tool's own
     up-to-date checks decide what to rebuild — no forced reconfigure;
   - **deletion** (clean, reset, delete, nuke) — keeps the `unknown` state its
     deletion already recorded (§5.7).
6. **Run** the requested operation normally, acquiring its locks as usual.

`lw daemon stop --force` is steps 1–5 against the runtime lock;
`lw daemon kill` is the same with step 1 skipped. Plain `lw daemon stop`
never kills (§19.11).

**Limits.**

- **Never another host.** A holder on another host is never signalled or
  killed: the command refuses and names the host (`run lw daemon stop there`).
  `lw unlock --force <lock>` removes a lock record **without** killing anything,
  after printing that the holder may still be running and writing.
- **Never the editor.** A lock held by an editor process (holder kind
  `editor`) is never signalled or killed: `lw: build/debug is held by nvim
  (pid 4242) — cancel the task there, or break the lock without killing it:
  lw unlock --force build/debug`.
- **No bypass.** Breaking locks never bypasses workspace trust (§17) or
  deletion safety (§15 invariant 3); the requested operation is checked as
  usual.
- **Non-interactive.** `--break-locks` works with `--no-input` (CI recovery);
  every kill and every forced unlock is printed on standard error and recorded
  in the runtime log (§19.10).

`--force` is not reused: on `lw build` it already overrides an output-artifact
conflict (§5.9, §16.28), and an unrelated meaning would make one flag do two
dangerous things.

**Known limitations.**

- On Windows an `lw` holder in another console cannot reliably be sent an
  interrupt, so step 1 is effectively skipped there for non-daemon holders and
  recovery goes straight to the kill.
- The process start time needs per-OS code (Windows `GetProcessTimes`, Linux
  `/proc/<pid>/stat`, macOS `proc_pidinfo`); where it is unavailable, holders
  on that host are judged by heartbeat alone (a dead holder is then reclaimed
  only after the heartbeat window, and a hung one is indistinguishable from a
  dead one).
- A process tree is enumerated by parent process id. On Windows that reaches
  native children only: a grandchild started through an MSYS/Cygwin shell
  (for example `sleep` under Git's `sh`) has no Windows parent link to the
  holder and survives the kill.
- A holder is identified by host name, process id and start time. Processes
  in different PID namespaces that report the same host name (containers
  sharing a hostname, or sharing a checkout over a bind mount) are not told
  apart: a holder in another namespace looks dead (its id is unknown here) or,
  if the id is taken, like a different process — its lock is reclaimed. Give
  such containers distinct host names, or do not share one checkout between
  them.
- `--break-locks` never signals the calling process or any of its ancestors;
  descendants are signalled only while they are still the process seen in the
  snapshot (same id and start time).

**Required tests.**

- The daemon killed (`SIGKILL` / forced termination) mid-build: the next
  command reclaims the runtime and build locks automatically; killed during
  configure, the units read `unconfigured` and the next build reconfigures;
  killed during the build step, they read `configured` and the next build does
  not reconfigure.
- The daemon suspended (`SIGSTOP` / suspended threads): the next command
  reports it as hung, not busy; `--break-locks` recovers and the suspended
  process is gone.
- A process killed at each step of §19.4 (after staging, after the journal,
  after each rename, before journal removal): the next load yields the old or
  the new state, never a mix.
- A lock record whose process id now belongs to a different process (start time
  differs): treated as dead, the unrelated process is never signalled.
- A lock record from another host: never killed; refused with the host named;
  `lw unlock --force` removes it with the warning.
- An editor-held lock: never killed; refused with the editor message.

### 19.6 Discovery: the handle file and the Runtime row

*Status: master — the handle (`daemon/handle.lua`, written and heartbeated
by `daemon/server.lua`), the Runtime row and `lw daemon status`; the running-task
lines (`daemon/running.lua`).*

A daemon publishes `<root>/.nvim/loomworks.daemon.json` after binding its
endpoint: `{ pid, host, os, start_time, endpoint, protocol, lw_version,
schemas = { user, cache }, session_generation, started_at, clients, busy,
idle_since, lock_nonce, key_id, exe }` (`start_time` is the daemon's process start time of
§19.5, `lock_nonce` its runtime-lock record's nonce, `exe` the path of the
executable it runs — for display only, such as the editor's version-mismatch
note, §19.16; never executed or trusted for a decision). `key_id` is a
non-secret fingerprint of the daemon key K it authenticates with (§19.8): the
first 16 hex digits of HMAC-SHA256(K, `"loomworks-daemon-key-id-v1"`). It
tells, without connecting, whether a daemon belongs to this lw's data
directory (machine key) — a daemon of another `LOOMWORKS_DATA_DIR`, such as a
test run's, has another key and could never complete the handshake with this
lw. It is one-way under its own label and is never part of a proof. A
development build's
`lw_version` is its source fingerprint (§19.9). It
refreshes the file's modification time on its heartbeat and rewrites it when
`clients`/`busy` change. Liveness is judged by the heartbeat, never by probing
the pid (§16.6). The handle is **discovery only**: the runtime lock (§19.2)
decides who the runtime is, and the handshake (§19.8) decides whether a client
may use it. A malformed handle is reported as unreadable, never as a live
daemon. A daemon that finds its handle removed while it runs rewrites it.
A rewrite stages the new file and renames it over the handle; on Windows that
rename fails while another process has the handle open (a client reading it,
an indexer, a scanner — opening it with delete sharing does not help: only a
rename's source may be open), so each rewrite retries it with backoff for a
bounded time (the daemon's own loop for about a quarter of a second). A
rewrite that still fails leaves the previous handle in place, never a partial
one, and removes its staged file; the daemon then rewrites again on a backoff
(up to about a second apart) and on every heartbeat until a rewrite succeeds,
so clients never keep reading an outdated `clients`/`busy`, and notes it in the
runtime log only once it has kept failing for a few seconds. The heartbeat
still refreshes the published file's time meanwhile. A record identical to the
one last written is not rewritten.

**Runtime row.** `lw status` shows one `Runtime` line computed **only** from the
handle and the runtime lock — it never launches or connects (the running-task
lines below may connect, never launch):

```
Runtime   daemon pid 4242, 2 clients, idle 12m
Runtime   daemon pid 4242, v0.1.43 (this lw is v0.1.44 — restarts when idle)
Runtime   daemon on OTHERHOST (pid 4242)
Runtime   attached: lw build (pid 4242)
Runtime   no daemon (starts on the next command)
Runtime   in-process
Runtime   stale daemon handle (pid 4242, 3h ago) — the next workspace command recovers it (daemon mode), or lw daemon stop
Runtime   daemon pid 4242 is not responding (no heartbeat for 2m) — lw daemon stop --force
Runtime   daemon pid 4242 (starting)
Runtime   unreadable daemon handle — the next workspace command recovers it (daemon mode), or lw daemon stop
```

`no daemon (starts on the next command)` is shown in `daemon` mode,
`in-process` in `in-process` mode, when neither the runtime lock nor a handle
exists.

**Running tasks.** Under the Runtime line, `lw status` lists the daemon's
running tasks, one line each: the operation (`kind`), the profile, the origin
(`lw` for `cli`, `editor`), the elapsed time since `started_at`, and the
percent when known:

```
Runtime   daemon pid 4242, 2 clients
  build  Debug:ninja-gcc   (lw)      1m12s  43%
  test   Release:msvc-17   (editor)  8s
```

A `reset --all` task (`meta.scope = "all"`, no
profile, §19.15 Reset) shows `--all` in the profile column.

It asks only a daemon the handle shows live, on this host, busy (a running
task makes it busy, §19.11) and with this lw's `key_id` — so an idle daemon
is never contacted — by connecting, authenticating and sending `status`
(§19.11), with a bound of about a second; it never launches one. `status` is
in the frozen control subset (§19.8), so this works across a version
mismatch, and the connection is never a `retire`. A reply without `tasks` (an
older daemon) shows `  running tasks: not reported by daemon lw <version>`; a
failed or timed-out query shows one line, `  running tasks: unavailable
(<reason>)`. The same reply's `tasks` also mark the profiles and units they
resolve to as running in the profile list's build state (§16.18), as the
editor shows an observed task (§19.16; a task without a profile, a `reset
--all`, marks every profile that has one of its units); nothing else of `lw status`'s output,
and never its exit status, depends on the query. `lw status` has no machine-readable (`--json`) form, so there is none
to extend.

#### 19.6.1 Listing every daemon of this user

*Status: master — `daemon/discover.lua` (the scan), `proc.processes`,
`lw daemon list`, `lw daemon stop --all` / `kill --all [--strays]`, the
`lw health` count line.*

`lw daemon list` lists every workspace daemon of the calling user **on this
host**, in any workspace, run from anywhere (no workspace needed). It is found
by a **process scan** — there is no per-user registry: lw writes nothing
outside the workspaces for it, so a crash or a power loss leaves no file to go
stale. It never launches, connects to or signals a daemon, and writes nothing.

**Scan.**

1. Enumerate the processes of this host with their executable names —
   Windows: one Toolhelp snapshot (`szExeFile`); Linux: `/proc/<pid>` entries
   **owned by the caller's uid** (name from `comm`); macOS: `proc_listallpids`
   + `proc_name` (fallback `ps -x -o pid=,comm=`).
2. Keep the candidates whose executable base name (lowercased, without
   `.exe`) is `lw`, starts with `lw-`, or is `luvi` or `nvim` — the hosts of
   §19.5 step 2. This process is skipped.
3. Read each candidate's command line (§19.5: Windows the process command
   line, Linux `/proc/<pid>/cmdline`, macOS `KERN_PROCARGS2`) and its start
   time; keep those that are `lw … daemon run` by the §19.5 identity rules. A
   command line that cannot be read (another user's process, access denied)
   is skipped. A kept process that is the parent of another kept process with
   the same `--root`, which started no earlier than it, is a pin redirect's
   wrapper (§16.23: the invoked lw waiting on the pinned `daemon run`), not a
   daemon, and is dropped — it is never listed, and never stopped or killed
   as a stray (killing its tree would kill the live daemon).
   *(Step 5i, `discover.is_relay` on the dispatch's own `stdio_form`.)* A
   `lw … daemon run --stdio` process is classified
   by the runtime lock R of its `--root`: when R names it (pid and start
   time), it is still a **runtime** — the attached `--stdio` of a repository
   pinned to a release before 5i (§19.10 "Connections", "Compatibility"), or
   the gated test-only `--stdio --private` runtime, which takes R with its
   pid and start time like any runtime (§19.10 "Tests"; with no handle it is
   listed as `starting`) — and is listed and treated as a daemon like any
   other. Any other `--stdio`
   process (and its pin-redirect wrapper) is a **relay** (§19.10
   "Connections"), never a daemon: it is listed as a connection under the
   daemon of its `--root` (counted in that row's clients, and in `--json` as
   `relays = [ { pid, start_time } ]` on that daemon's entry), never as a
   daemon row or a stray, and never stopped or killed — `kill --all --strays`
   skips it. A relay whose root has no listed daemon (it is connecting,
   launching, waiting on a retiring daemon, or a `--no-launch` relay waiting
   for one) is not listed.
   This is decided on R alone, so an attached `--stdio` runtime of a release
   before 5i that R no longer names — R taken over by another runtime,
   unreadable, or its root deleted — is classified as a relay: it is not
   listed (not as a stray either), and `kill --all --strays` (and
   `kill_stray` on it) refuses it. That is the accepted cost of never acting
   on a connection: end such a process with the operating system's tools.
4. The daemon's workspace is its `--root <dir>` (or `--root=<dir>`) argument —
   every launched daemon has one (§19.10). One run by hand without it is
   listed with **root unknown**.

The scan is bounded by the number of processes; the command lines read are
only the candidates'. It takes tens of milliseconds for a few hundred
processes; `--json` reports the time it took.

**Classification.** For each daemon with a root, its runtime lock R (§19.2)
and handle (§19.6) are read — files only:

| State | Test |
|--|--|
| `live` | R names this process (pid and start time) and the handle names it too; clients, busy, idle time and version come from the handle |
| `starting` | R names it, no handle yet; or R is absent and the process started less than 30 seconds ago (a daemon takes R first thing — until then it is starting, not a stray) |
| `hung` | R names it and its heartbeat is stale (§19.5) |
| `stray` | R names another holder or none, the handle names another process, or the root directory is gone — a daemon that is not its workspace's runtime (it lost its lock, is exiting, or was left over); never connected to |
| `unknown root` | no `--root` on its command line |

A daemon whose handle names it is also marked by its key: `same_key` is false
when the handle's `key_id` (§19.6) is not this lw's — a daemon of another
loomworks data directory — and null when the handle has no `key_id` (an
older daemon) or does not name it. Computing this lw's key id only reads the
machine key; none is created.

A handle or lock record that names a process the scan did not find (dead, or
its pid reused by another program) produces no entry: the list shows
processes, not files. A daemon on another host is not on this host's process
list; its workspace's `Runtime` row shows it (§19.6).

**Output.**

```
PID    UPTIME  STATE           CLIENTS  VERSION  ROOT
4242   2h      live, idle 12m  0        0.1.43   /home/me/src/app
4310   5m      live, busy      1        0.1.43   /home/me/src/lib
4388   1m      stray           -        -        /tmp/old-checkout  (the runtime lock names pid 4401)
4410   3m      live, idle 3m   0        0.1.43   /tmp/test-ws  (other data dir)
4 daemons (2 idle, 1 stray, 1 other data dir) — stop them with: lw daemon stop --all
```

There is one row per daemon — exactly the entries `--json` prints for the
same scan — and the summary counts those rows. Every column is filled: `-`
where the value is unknown (the clients and version of a daemon whose handle
does not name it; an uptime whose start time cannot be converted). STATE is
the state above (`unknown root` for `unknown_root`); a `live` daemon adds
`busy` or `idle <time>` (with clients, plain `live`). A daemon that is not
`live` or `hung` has its reason after the root, and one of another data
directory `other data dir`. A development build's version is shown with its
source fingerprint cut to 8 hex digits (`--json` has it whole).

No daemon: `no workspace daemons are running`. `--under <dir>` keeps the
daemons whose root lies under `<dir>` (separator-bounded, case-insensitive on
Windows); a daemon with an unknown root is then left out. `--json` prints
`{ schema = 1, scan_ms, daemons = [ { pid, start_time, root, state, reason,
uptime_s, started_at, clients, busy, idle_since, lw_version, protocol,
endpoint, same_key, relays } ] }` (absent values are `null`; `relays` is
always an array, step 3), sorted by root.

**Stopping all.** `lw daemon stop --all [--force]` and `lw daemon kill --all`
(each accepting `--under <dir>`) apply `lw daemon stop [--force]` /
`lw daemon kill` (§19.11, §19.5) to the workspace of every `live`, `starting`
or `hung` daemon listed — through that workspace's runtime lock, with all its
rules: never another host, never an editor holder, plain `stop` never kills,
a kill only of the holder its lock record names, identity-verified. One line
per daemon, prefixed with its root. A **stray** or **unknown root** daemon is
not its workspace's runtime and cannot be asked to stop: it is skipped with a
hint, unless `lw daemon kill --all --strays` was given, which kills it — only
after its command line is read again and is still `lw … daemon run` for that
root (or with no `--root`, for an unknown root) with the same start time,
never this process or one of its ancestors; if it held its workspace's runtime
lock, the lock is then reclaimed per §19.5. `--strays` is refused without
`kill --all`. A daemon of **another data directory** (`same_key` false) is not
this lw's: `stop --all` and `kill --all` skip it with `<root>: daemon pid <pid>
belongs to another loomworks data dir (different key) — skipped` and never
connect to it (`kill --all --strays` still kills such a daemon when it is a
stray, as above). A daemon whose handle has no `key_id` and whose handshake
then does not verify is reported and skipped the same way, as one that did not
prove this lw's daemon key. Neither counts as left running: the exit status
is 0 when none of this lw's listed daemons is left running, 1 otherwise.

**Health.** `lw health` (area `lw`) shows one informational line when this
user runs any daemon on this host: `2 workspace daemons running (1 idle) —
lw daemon list`.

### 19.7 Endpoint and access control

*Status: master (`daemon/endpoint.lua`; the DACL through LuaJIT FFI).*

The endpoint is a trust boundary — a peer that can issue commands can run
builds, i.e. execute code as the owner — so it is restricted by the operating
system **and** gated by authentication (§19.8).

- **POSIX:** a Unix-domain socket in a short per-user directory created `0700`
  and verified to be owned by the caller (`$XDG_RUNTIME_DIR/loomworks`, else
  `$TMPDIR` / `/tmp` with a `loomworks-<uid>` directory). The socket is named by
  a short hash of the normalized workspace root, so the path fits the `sun_path`
  limit (about 104 bytes on macOS, 108 on Linux) regardless of repository depth.
  A stale socket file is unlinked by a daemon or client only while holding
  the runtime lock. Outside that, only housekeeping and `lw cleanup` remove a
  socket, under the conditions of §16.40 (it refuses a connection, is older
  than an hour, and is put back if a daemon bound the name meanwhile).
- **Windows:** a named pipe whose name contains a hash of the user and the
  workspace root. Immediately after creating it, the daemon replaces its
  security descriptor (`SetSecurityInfo` through the host's foreign-function
  interface) with a protected DACL granting full access to the owner's SID and
  `SYSTEM` only and an explicit deny for the `NETWORK` SID. A daemon that cannot
  apply the DACL does not serve and exits with an error.

Clients read the address from the handle, and use it only when it is an
address a daemon of this workspace binds — on Windows exactly the pipe name
above; on POSIX one of the per-user socket paths of the client's own
environment, or — since the daemon binds the first path of the environment
that launched it, which a client from ssh, cron, `sudo -u` or a container may
not share — any `<dir>/<root hash>.sock` named for this workspace where `dir`
is a real directory (not a link) owned by the caller with mode `0700` and the
file is a socket owned by the caller, whatever the current environment. A
socket is removed only under the same conditions. Any other address (a
remote `\\host\pipe\…`, another user's socket) marks the handle as
untrusted: nothing is connected to, and the command says so. The handle sits
in a `.nvim/` other local users may be able to write; connecting to a remote
pipe would hand the user's credentials to that host.

### 19.8 Wire protocol and authentication

*Status: master for framing, authentication and the frozen control subset
(`daemon/protocol.lua`, `daemon/auth.lua`, `daemon/server.lua`,
`daemon/client.lua`; protocol version 3: 2 plus the routed `build` request
and its task stream, §19.15; protocol version 4: 3 plus the observer role,
`model_change` and `retiring` broadcasts, §19.11, §19.12, §19.16; protocol
version 5: 4 plus the routed `test` request, §19.15; protocol version 6: 5
plus the `prepare_run` request, §19.15; protocol version 7: 6 plus
`origin` in the task `start` meta and `tasks` in the `status` reply, §19.11,
§19.15, §19.16; protocol version 8: 7 plus the routed `clean` request,
§19.15; protocol version 9: 8 plus the routed `reset`
request and its `confirm` outcome, §19.15; protocol version 10: 9 plus
the `snapshot` and `query` requests and the model fields of the `welcome`
header, §19.13, §19.14; protocol version 11, step 5g.1: the transport-only
version — the envelope, the root object, `protocol_min`, `welcome.objects`
(below and §19.20; `daemon/interfaces.lua`, `proto/envelope.lua`) — accepting
clients of 10 and 11); the rest of the broadcasts #88.*

**Framing.** A message is a JSON object prefixed by its decimal byte length
and a newline (`<len>\n<json>`). Every request carries a `req_id` that its
reply echoes; broadcasts carry none. An unknown kind, a malformed frame or a
handler error yields a typed error reply, never a crash.

**Authentication** (mutual, before anything else). Let *K* =
HMAC-SHA256(machine key §17.2, `"loomworks-daemon-v1"`), and *E* the endpoint
address from the handle.

1. client → `hello { protocol, lw_version, schemas, client = cli|editor, role?, nonce = Nc }`
   (`role = "observer"`: a client that only watches, §19.16 — an addition a
   daemon of an older protocol ignores)
2. daemon → `challenge { protocol, lw_version, schemas, session_generation,
   server_nonce = Ns, server_proof = HMAC(K, "server\n" .. E .. "\n" .. Nc .. "\n" .. Ns) }`
3. client verifies `server_proof`; on failure it closes the connection without
   sending anything else and reports the endpoint as untrusted. Otherwise →
   `auth { client_proof = HMAC(K, "client\n" .. E .. "\n" .. Ns .. "\n" .. Nc) }`
4. daemon verifies → `welcome { header, seq, clients, busy, retiring }` (§19.13).
   Welcome fields are only ever added — model fields inside `header`, transport
   fields beside it (`objects`, protocol 11, §19.20) — and a later field never
   replaces `root`, `pid`, `lw_version` or `session_generation`.

Nonces are 32 random bytes (hex); proofs are compared in constant time. Before
`welcome` the daemon accepts only `hello` and `auth`, caps a frame at 64 KiB
(a longer length prefix closes the connection before the payload is read),
closes a connection that has not authenticated within about 5 s, and sends no
broadcast to it. A failed proof closes the connection with no detail. Because
the server proves knowledge of *K* first, a process squatting the endpoint
cannot impersonate the daemon to a client. The loopback transport (§19.1) skips
authentication; it never leaves the process. Its connection starts in the
authenticated state — the server sends `welcome` over it and nothing before —
and is then served exactly as an authenticated pipe connection (frame cap,
requests, replies, task streams, broadcasts, flow control); closing either end
is end-of-stream to the other. The private standard-I/O transport (`lw daemon
run --stdio --private`, tests only, §19.10 "Tests", §19.20) is a private pipe too: its connection is a child of
the process that spawned it, so the daemon answers that process's `hello`
directly with `welcome` — no `challenge`, no `auth`, the nonce ignored; the
versions in `hello` are negotiated as on the socket, and anything other than
`hello` first closes it. Closing the daemon's standard input ends that
connection and stops the runtime: as for any disconnect (§19.15), the tasks
the connection owns are cancelled, and the process exits once they ended
(a process that spawned it and goes away leaves no build running). The socket transport keeps the challenge.
*(Step 5i, `daemon/relay.lua`: `lw daemon run --stdio` is a **connection**, never a
daemon — §19.10 "Connections". It connects to the workspace's shared daemon
over the socket (starting it first if none runs), authenticates there with the
challenge as any client, and then relays frames opaquely between its standard
input/output and that connection; its own client still sends `hello` first
and gets `welcome`. Closing its standard input closes only that connection:
the tasks it owns are cancelled (§19.15), the daemon keeps running. The
private-pipe server described above then remains only for the conformance
runner's fresh, isolated daemon, behind the hidden, gated `--private` flag
(§19.10 "Connections", "Tests") — never a user-facing attached mode, and
unreachable without that gate.)*

**Relay handshake.** *(Step 5i, `daemon/relay.lua`.)* The relay's client sees the
pipe handshake above (`hello` first, then `welcome`, no `challenge`); the
relay runs the socket handshake on its behalf:

1. The relay reads the client's `hello` from standard input **first** —
   before it discovers, launches or connects to anything — so the daemon's
   5 s authentication deadline never covers a launch. Anything other than a
   `hello` first, or none within about 5 s, ends the relay (exit status 15,
   §19.10 "Relay exit status").
2. It then connects (launching first if needed, §19.10) and sends the socket
   `hello` with that hello's `protocol`, `protocol_min`, `lw_version`,
   `schemas`, `client` and `role`, and a nonce of its own (the client's
   nonce is not used).
3. It verifies `server_proof` before forwarding anything; on failure it
   sends nothing more on either side and exits (status 12). It then sends
   `auth`. `challenge` and `auth` never reach its client.
4. It forwards the daemon's `welcome`, adding two fields, and from then on
   copies frames both ways unchanged:
   - `daemon = { protocol, protocol_min, lw_version, schemas,
     session_generation, pid, start_time, exe? }` — the daemon's side of the
     handshake, taken from the `challenge` the relay verified (`pid`,
     `start_time` and `exe` from the handle it connected through, §19.6;
     `pid` and `start_time` identify that daemon instance, as for a lock
     holder, §19.5, so a client can name it to `--skip-instance`, §19.10 "No
     launch"; `start_time` is absent when the handle carries none, and such
     a daemon cannot be named, §19.16 "Skipping an incompatible daemon";
     `exe` for display only, absent when unknown). The client
     applies its version rules (§19.9) to these, as it would to a
     `challenge`.
   - `via = "relay"`. A client that gets a `welcome` without `via` is
     talking to an attached runtime (a repository pinned before 5i): the
     editor treats it as such and never sends `retire` over it.

   Both are optional fields added to `welcome`, which the frozen-subset rule
   below allows (added, never removed, renamed or retyped; a receiver
   ignores a field it does not know); an attached runtime omits both.
5. When the `welcome` says `retiring`, the relay does not forward it: it
   closes that connection, waits for the retiring daemon's runtime lock to
   be released — at most `RELAY_RETIRE_WAIT` (60 s) — launches the
   successor (§19.10) and repeats from step 2. A daemon still holding the
   lock after that bound ends the relay with status 14, its standard error
   naming that daemon (§19.10 "Relay exit status"). A `--no-launch`
   relay instead keeps waiting without a bound and never launches the
   successor (§19.10 "No launch").

**Frozen control subset.** Framing, `hello`/`challenge`/`auth`/`welcome`,
`ping`, `status`, `stop` and `retire` (§19.9) never change shape across
versions, so any two versions can always authenticate, inspect and retire each
other. Fields of these messages are only ever added, never removed, renamed or
retyped, and a receiver ignores a field it does not know. *(Step 5g.1.)*
From protocol 11 the frozen subset also covers the `retiring` broadcast, the
envelope kinds and their routing fields (`kind`, `req_id`, `object`, `iface`,
`v`, `method`, `sub_id`, `task_id`), the transport error codes (§19.20; new
codes may be added, a client treats an unknown one as `internal`) and the root
interface `loomworks.Root/1` (§19.20), so any two versions sharing a transport
can also discover each other. *(Planned, step 5i.)* The relay's
`welcome.daemon` and `welcome.via` (above) are such additions: optional, they
change no existing field and do not move `protocol`.

**What the protocol number versions.** *(Step 5g.1.)* From protocol 11,
`protocol` versions the **transport** only: the framing, authentication, the
handshake, the message envelope (`call`, `ok`, `error`, `signal`, `task`;
§19.20), flow control (§19.15) and the root object. Everything a client does
beyond that is an **interface** (§19.20) with its own version, chosen per call;
a new operation, field or view never changes `protocol`. After 11 the number
moves only for a genuinely breaking transport change. `hello` and `challenge`
gain an optional `protocol_min`, so each side states a range
`[protocol_min, protocol]` (absent: `protocol_min = protocol`); `welcome` gains
an optional `objects` list (§19.20). There are no capability flags. A daemon
of protocol 11 accepts clients of 10 and 11: the request kinds of protocol 10
(`build`, `test`, `prepare_run`, `clean`, `reset`, `snapshot`, `query`) and its
broadcasts (`model_change`, task events to every connection) are served
unchanged as **v0 aliases** of the corresponding interface methods — the same
handlers, with an argument and result adapter, never a second implementation —
until `protocol_min` is raised to 11 (§19.19, retirement of protocol 10). A v0
request gets a v0 reply (`error` a string); only an interface call gets the
structured `error` object.

### 19.9 Version handshake

*Status: master (`daemon/version.lua`, `daemon/ensure.lua`), applied by every
workspace command in `daemon` mode. During the transition a version-bypass
run is the in-process path, and a daemon with newer schemas is reported in
one line and not used — the command itself still runs in-process, where the
file-level checks of §2.7 apply. The transport range under "From protocol
11" is step 5g.1 (`version.negotiate`; an editor observes a daemon whose range
overlaps its own); the CLI policy (`ensure.policy`, `describe`) and the
generalised busy rule (`Server:conn_busy`, `status.busy_clients`) are
implemented, step 5g.3; the editor retirement below is implemented, step 5h.5
(`daemon/editor_retire.lua`, `Observer:_weigh_retire`).*

Client and daemon are the same binary, so after a self-update (§16.32) or a pin
change (§16.24) a newer client can meet an older daemon. Both sides send their
protocol version, host version and the working-copy and cache schema versions
in the handshake. A CLI client **matches** a daemon when all of them are equal
(a development build compares its source fingerprint as its version: the
paths, sizes and modification times of its Lua sources whenever they are on
disk — a development source tree or a directory bundle — so editing a source
is a mismatch; only a fused executable, whose sources cannot change, uses the
executable itself, identified by its resolved path, so every spelling of it
(a link, a differently cased name) is the same executable). An editor
client **observing** a daemon (§19.16) needs less: an equal protocol and schemas
no newer than its own — the daemon's host version may differ (the editor's
code ships with the plugin, the daemon's with the resolved host binary).

On a mismatch, after authenticating:

- **Idle daemon** (no connection other than this one is busy — none owns a
  running task or has a request in flight, "Busy" below) — the client stops
  it (§19.11) and launches its own binary in its place; a connection that
  only observes or subscribes (an editor) never counts as busy.
- **Busy daemon** — the client sends `retire`: the retiring daemon accepts no
  new operations from any client (each is `declined`, and that client runs it
  in-process), finishes the ones already running, and exits once no
  connection is busy; the next command launches the current binary.
  The client runs **this** command as a **version-bypass run**: attached, but
  without the runtime lock (§19.2), holding only its operation locks (§19.3),
  and prints one line:

  ```
  lw: the workspace daemon runs lw v0.1.43 and is busy — running this command without it; it restarts when idle
  ```

A client never stops a busy daemon, and never drives a daemon it does not
match. A daemon whose schemas are newer than the client's is never stopped by
it; the client refuses with the update message of §2.7 "Reading a newer file".

**From protocol 11.** *(Transport: step 5g.1; the CLI policy and the busy rule: step 5g.3; the
editor retirement: step 5h.5.)* The rules above split
into a protocol rule and a client policy:

- **Transport.** Client and daemon agree on the highest transport version in
  the overlap of their `[protocol_min, protocol]` ranges (§19.8); with no
  overlap the daemon is incompatible. Interfaces are not negotiated here:
  the client chooses a version per interface and stamps it on each call
  (§19.20). Shipped editors of protocol 10 observe only a daemon whose
  protocol equals their own (§19.16), so in practice "11 accepts 10" serves
  clients of the 11 era that still send the v0 request kinds, until step
  5g.3.
- **`lw_version` equality is the CLI's policy** for routed operations — pin
  semantics and behavioural parity, which no interface version expresses. Before
  routing, the CLI compares `describe().binary.lw_version` (§19.20) with its own
  (and the schema versions as above) and applies the idle-restart / busy-retire
  and bypass flow unchanged. The daemon enforces version equality only for
  interfaces flagged `same_build` (§19.20). An editor never requires an equal
  `lw_version` or equal schemas: it needs a transport overlap and, per feature,
  the interface versions it uses (§19.16).
- **Busy.** A connection counts towards *busy* only while it **owns a running
  task or has a command in flight**. A connection that only subscribes —
  views, task observation, an editor with no operation of its own — never does:
  the observer rule above applied to every connection. A CLI restarting an idle
  daemon is therefore safe for a connected editor, which reconnects,
  re-describes and re-subscribes (§19.16). The CLI still never stops a busy
  daemon.
- **Editor retirement** (step 5h.5). The editor retires a daemon only when it
  is idle **and incompatible** with the editor (§19.16 "Retiring an
  incompatible daemon"), and only when the binary the editor selected is
  itself compatible. A daemon that is merely older than that binary is never
  retired by the editor, nor is one whose schemas are newer than the editor's;
  the editor retires a daemon of a given `lw_version` at most once per
  workspace per editor session. Retiring for "older" would make the editor
  and the CLI, which requires an equal `lw_version`, restart each other's
  daemon in turn. A daemon whose only incompatibility is older schemas stays
  observed while the editor waits for it to go idle, and for the whole
  session when the editor declines to retire it.

### 19.10 Launch

*Status: master (`daemon/launch.lua`, `daemon/ensure.lua`,
`daemon/rlog.lua`). In `daemon` mode the workspace commands launch — the
commands that need no workspace (`status`, `health`, `pull`, `worktree`,
`settings`, `help`, `daemon …`) and the recovery commands (`trust`, `nuke`,
`unlock`) never do; the `Runtime` row says the daemon "starts on the next
command". The ensure step of a command waits about a second per step at most
(connect + handshake, `ping`), and for a daemon still starting at most about
a second, once, before running without it. A command the daemon would run (a
routed `lw build`, §19.15) waits up to about 5 seconds instead, for each step
and for the one wait on a starting daemon: under machine load a healthy daemon
can miss the second, and the build would then run in-process exactly when the
daemon helps most. A daemon already classified hung (§19.5: alive, heartbeat
stale) is reported at once either way; the longer bound only applies to a
live-but-slow one. A `lw daemon run` that finds the runtime lock
held exits with status 3, which the launching client reads as "another daemon
won".*

A client that finds no live daemon (no handle, a stale handle, or a lock whose
holder is gone) launches `<own executable> daemon run --root <root>`:

- **Detached**, in a new process group/session, with **no inherited standard
  handles** (on Windows, standard input, output and error are not inherited;
  on POSIX they are `/dev/null`); the daemon writes its own **runtime log**
  inside the workspace, `<root>/.nvim/loomworks.daemon.log`, capped at a few
  megabytes with one rotated predecessor (`.log.1`). Each line is appended
  with the file opened and closed again, so no process keeps it open, and as
  one atomic append (the system places the write at the end of the file:
  O_APPEND, on Windows append-only access), so lines that a client and the
  daemon it just launched write at the same moment are both kept. A write
  creates `.nvim/` only when the workspace root exists, and never creates the
  root: a daemon whose workspace was removed does not bring it back. A file at
  the log's name that is not lw's runtime log is never written, rotated or
  removed (§16.40). `lw daemon status` names the log when it exists. (Earlier versions kept it in the
  per-user state directory; §16.40 removes those files.)
- **Working directory**: the per-user state directory — never the workspace,
  so the daemon never holds the workspace directory open or busy.
- **Environment**: the client's, de-duplicated (on Windows case-insensitively,
  keeping the entry the process itself resolves); when the client runs from a
  development source, `LOOMWORKS_LUA` is forwarded so the daemon runs the same
  source.
- **Readiness**: the client waits (about 10 s) for a handle naming a live
  daemon, and watches the child for an **early exit**. A child that exits
  because another daemon holds the runtime lock is not a failure — the client
  connects to that one. Any other early exit, or no handle in time, is a
  **launch failure**: the client runs the command attached (§19.1), printing
  `lw: could not start the workspace daemon (<reason>); running without it`.
  It never retries in a loop.

Concurrent launches resolve on the runtime lock: one daemon wins, the others
exit, all clients connect to the winner.

**Connections.** *(Step 5i: the relay with `--no-launch`, `--skip-instance`
and the gated `--private` is implemented, `daemon/relay.lua`, and so is its
`lw daemon list` / `kill --all --strays` classification (§19.6.1 step 3), and
the idle rule with its background-work cap (§19.11 "Idle exit"), and the
CLI's two-stage Ctrl-C (§19.15 "Task ownership"), and the editor's use of it
(§19.16 "Through the relay", `daemon/client.lua` `relay`) with the `--retiring`
flag ("A named retiring daemon" below), step 5i PR G1, and the editor's
incompatible-daemon policy over it (`--skip-instance`), PR G2.)* Every client process is a
**connection** to the one shared daemon of its workspace, never a daemon:

- **Connect or start.** Every CLI command that uses the daemon — the
  commands that already do so today, in `runtime-mode daemon` (the ensure
  step and the routed operations above and §19.15); step 5i routes no new
  command, and the `in-process` default does not change — and
  `lw daemon run --root <root> --stdio`, connects to the workspace's daemon
  over its endpoint, or first launches the normal detached daemon above when
  none runs, then connects. `--stdio` then **relays** frames opaquely between
  its standard input/output and that connection (it authenticates on the
  socket like any client, §19.8 "Relay handshake"; it interprets no
  interface, so it never changes for a new one). It replaces the separate
  `lw daemon attach --stdio` bridge planned earlier. Each relay step
  (connect + handshake, the one wait on a starting daemon) is bounded as for
  a routed command (about 5 s). A daemon still starting after that one wait
  ends the relay with status 11 (not responding). Before it connects, the
  relay checks the handle: a `key_id` (§19.6) that is not this lw's, or an
  endpoint that fails the endpoint check (§19.7), ends the relay with status
  12 — nothing is connected to — as a failed `server_proof` does.
- **Lock held by an attached run.** When the runtime lock is held by an
  **attached run** (§19.2: a CLI command running without a daemon), the relay
  neither launches nor fails: it waits — no time bound, for as long as its
  standard input stays open — re-reading the runtime lock about every 2 s,
  until that run ends, and then continues connect-or-start from the start
  (a daemon may have been started meanwhile, or it launches one). The client
  closing standard input (EOF) while it waits ends the relay with status 0.
  No exit status is added for this case.
- **No launch.** `lw daemon run --root <root> --stdio --no-launch` is the
  relay that **never launches** a daemon (the editor's after a drop such as
  `lw daemon stop`, after a relay's status 10 or 11, and while a retiring
  daemon is still busy, §19.16 "Through the relay"). It reads the client's `hello` first as any relay
  (§19.8 "Relay handshake", status 15), then waits inside lw for a live
  daemon of its root: it re-reads the runtime lock and the handle about every
  2 s (the cadence at which the editor watched the handle before), and
  connects as soon as one is live, with the same discovery, handshake and
  checks as connect-or-start — the handle's `key_id`, the endpoint check
  and `server_proof` (status 12), another host (13), not responding (11). Once connected it
  relays exactly as above. A daemon still starting (lock held, handle not yet
  published) is waited on, as is a retiring one: on a `welcome` that says
  `retiring` the relay closes that connection, forwards nothing, and keeps
  waiting — no `RELAY_RETIRE_WAIT` bound, and no successor launched. When the
  retiring daemon it saw has released the runtime lock and no other daemon is
  live, it exits with status 16 (so the editor launches the successor itself,
  §19.16 "Retiring"); a successor another client started first is connected
  to instead. The wait has no time limit: it lasts while standard input stays
  open, and when the client closes standard input (EOF) during the wait the
  relay exits 0, having launched nothing. Statuses 10 and 14 are never a
  `--no-launch` relay's. `--no-launch` without `--stdio`, or with
  `--private`, is usage (status 2).
- **Skip an instance.** `--no-launch --skip-instance <pid>:<start_time>`
  (the editor's after it found that daemon incompatible, §19.16 "Through the
  relay") names one daemon instance by process id and process start time
  (§19.5; the handle's `pid` and `start_time`, as `welcome.daemon` reports
  them, §19.8 "Relay handshake"). The relay treats that daemon as not
  present: it never connects or relays to it, and while it holds the
  runtime lock (or its handle is the live one) the relay keeps waiting as a
  `--no-launch` relay waits on a starting daemon — no bound, nothing
  launched, status 0 on EOF. Once the lock is released, or held by a
  different instance, the relay proceeds as a plain `--no-launch` relay: it
  connects to a live daemon of another instance when one appears (a
  `retiring` one is waited on as above). It never exits 16 for the skipped
  daemon — 16 is only for a retiring daemon it connected to — so a skipped
  daemon that exits with none other live leaves the relay waiting, as after
  a stop. `--skip-instance` names at most one instance; it is usage (status
  2) without `--no-launch` (an ordinary relay could neither use the skipped
  daemon nor launch while it holds the lock, so it would only wait, which is
  what `--no-launch` is), or when its value is not `<pid>:<start_time>`.
- **A named retiring daemon.** *(Step 5i PR G1.)*
  `--no-launch --retiring <pid>:<start_time>` (the editor's after a relay
  exited 14, with the instance that relay's `retiring` line named, "Relay
  exit status" below and §19.16 "Through the relay") names one daemon
  instance (as for `--skip-instance`) that the relay treats as a retiring
  daemon it already saw, as if it had connected to it and got a `welcome`
  that says `retiring`. It closes a race a plain `--no-launch` relay leaves open: a
  retiring daemon that exits after the status-14 relay gave up but before
  this relay first looks is never seen retiring, so a plain `--no-launch`
  relay would wait on as after a stop and never exit 16. With `--retiring`,
  while that instance holds the runtime lock (or its handle is the live
  one) the relay waits on it as on a retiring daemon ("No launch" above: no
  bound, nothing launched); once that instance no longer holds the lock —
  including when it is already gone at the relay's first check — and no
  other daemon is live, the relay exits 16. Otherwise it is a plain
  `--no-launch` relay: a live daemon of another instance is connected to (a
  `retiring` one is waited on as above), status 0 on EOF. `--retiring`
  names at most one instance; it is usage (status 2) without `--no-launch`,
  or when its value is not `<pid>:<start_time>`. The editor never passes it
  together with `--skip-instance`; whether that combination is usage is not
  specified.
- **Relay buffering.** The relay bounds what it buffers in each direction:
  while the queue of frames waiting to be written to one side holds more
  than `RELAY_HIGH_WATER` (4 MiB) it stops reading the other side, and
  resumes once that queue has drained below half of it. A client that stops
  reading therefore stops the relay reading the daemon, so the daemon's
  owner flow control (§19.15 "Task stream") still reaches the running step
  through the relay, and the relay's memory stays bounded. Before the
  daemon's `welcome` the relay keeps what the client pipelines after its
  `hello` (forwarded after `welcome`); more than `RELAY_HIGH_WATER` of it is
  a protocol violation that ends the relay with status 15 — the relay never
  stops reading a client it has not yet relayed for, so it always sees that
  client's EOF.
- **Closing a connection** — killing the `--stdio` process, closing its
  standard input, a CLI command ending or interrupted — closes only that
  connection: the tasks it owns are cancelled (§19.15 "Task ownership"), the
  daemon keeps running under §19.11.
- **Only the daemon owns the workspace runtime**: the runtime lock, the handle,
  the endpoint and the identity are the daemon's. A relay takes no lock,
  writes no handle and registers nothing; `lw daemon list` and
  `kill --all --strays` show it as a connection of its daemon (§19.6.1).
- **Tests.** The conformance runner (§19.20) needs a fresh, isolated daemon
  per case. It gets one through the hidden `--private` flag of
  `lw daemon run --stdio`, which keeps today's attached standard-I/O runtime
  (§19.8: the private pipe, no challenge) for tests only. `--private` is
  refused (status 2, `lw: --private is for tests only`) unless the
  environment variable `LOOMWORKS_TEST_PRIVATE_STDIO` is `1`; it is not in
  `--help` and not in completion. Nothing else reaches the private no-auth
  path: without the flag and the variable, `--stdio` is always the relay.
  A per-case temporary workspace root remains the alternative when a case
  needs the shared-daemon path itself. `--no-launch` is tested on such a
  root: with no daemon it waits and launches nothing (no runtime lock, no
  handle appears); once a daemon is started for the root it connects and
  relays (`welcome` with `via`); closing its standard input while it waits
  ends it with status 0; a retiring daemon is waited on, never relaunched
  over, and its exit with no other daemon live ends the relay with status 16.
  `--skip-instance` is tested on the same root: with the named daemon live
  the relay never connects to it (the daemon sees no connection) and keeps
  waiting; after that daemon stops it stays waiting (no status 16) and
  connects to the next daemon started for the root; a value naming another
  instance (different start time) does not skip the live one; without
  `--no-launch`, or with a malformed value, it is status 2. `--retiring`
  is tested likewise: naming an instance already gone,
  with no other daemon live, it exits 16 at once; naming a live retiring
  daemon it waits, launches nothing, and exits 16 once that daemon has
  released the lock; with another daemon live it connects to that one;
  without `--no-launch`, or with a malformed value, it is status 2. The
  status-14 line is tested with a retiring daemon kept
  busy past `RELAY_RETIRE_WAIT` (the bound shortened for the test): the
  relay exits 14, its standard output is empty, and its standard error is
  its `lw: ...` line followed by exactly `retiring <pid>:<start_time>`
  naming that daemon's handle `pid` and `start_time`; a `--no-launch
  --retiring` relay given that value exits 16 once the daemon has released
  the lock.
- **Compatibility.** A repository pinned to a release from 0.1.43-beta.15 up
  to the one before the release that ships this step still gets that
  release's attached `--stdio` (it works, but is not shared with the CLI; its
  `welcome` has no `via`, §19.8 "Relay handshake", so the editor never sends
  `retire` over it); a pin older than 0.1.43-beta.15 is already refused for
  the daemon commands (§16.23 "A pin older than the command",
  `pin.REDIRECT_SINCE`).

**Relay exit status.** *(Step 5i, `daemon/relay.lua`.)* A relay that fails before
forwarding `welcome` writes nothing to standard output, one `lw: ...` line to
standard error (on status 14 followed by the retiring-instance line below),
and exits with:

| Status | Meaning |
|--|--|
| 0 | the client closed standard input (with `--no-launch`, also while waiting, having launched nothing; for any relay, also while waiting on an attached run's runtime lock), or the daemon closed the connection after `welcome` |
| 1 | standard input or output is unusable, or an internal error |
| 2 | usage: no `--root`, `--private` without `LOOMWORKS_TEST_PRIVATE_STDIO=1` or without `--stdio`, or `--no-launch` without `--stdio` or with `--private`, or `--skip-instance` without `--no-launch` or not `<pid>:<start_time>`, or `--retiring` without `--no-launch` or not `<pid>:<start_time>` |
| 10 | could not start the workspace daemon (launch failure above; never with `--no-launch`) |
| 11 | the daemon is not responding (hung, §19.5; connect/handshake past its bound; or still starting — lock held, handle not published — after the relay's one bounded wait; never with `--no-launch`, which keeps waiting on a starting daemon) |
| 12 | the handle names another loomworks data dir's key (`key_id`, §19.6), its endpoint failed the endpoint check (§19.7), or the endpoint did not prove this lw's key (another loomworks data dir, or not a loomworks daemon) — only the relay's own `hello` (versions and its nonce, no secret) was sent; nothing from the client is forwarded |
| 13 | the workspace daemon runs on another host |
| 14 | a retiring daemon still held the runtime lock after `RELAY_RETIRE_WAIT` (never with `--no-launch`, which keeps waiting); standard error also names that daemon (`retiring <pid>:<start_time>`, below) |
| 15 | the client sent no valid `hello` first (another frame, or a `hello` whose forwarded fields are not of their types or that does not fit the 64 KiB pre-authentication frame cap re-encoded), or none within about 5 s; or it sent more than `RELAY_HIGH_WATER` after `hello` before `welcome` ("Relay buffering") |
| 16 | `--no-launch` only: the retiring daemon it waited on (one it connected to, or the one `--retiring` names, also when already gone at its first check) released the runtime lock and no other daemon is live — the caller decides whether to launch (never for a `--skip-instance` daemon) |

**Retiring-instance line.** *(Step 5i PR G1.)* A relay that exits
14 writes, after its `lw: ...` line, exactly one more standard-error line,
the last it writes: `retiring <pid>:<start_time>` — the literal word
`retiring`, one space, then the retiring daemon's instance in the form
`--retiring` and `--skip-instance` take (§19.10 "A named retiring daemon"):
exactly its instance id (§19.5) — the handle's `pid` in decimal, a colon,
and its `start_time` verbatim (an opaque string that may itself contain
colons, e.g. `win:<creation time>`), as in `retiring 1234:win:5678` — with
no other characters, ending in the platform's newline. It names the daemon whose
runtime lock the relay waited on. A relay that does not know both values
(a handle without `start_time`) writes no such line. No other status writes
it, and nothing else on a relay's standard error starts with `retiring `.
The editor passes the value to `--retiring` (§19.16 "Through the relay").

Status 3 ("another daemon won", above) is never a relay's: a relay that
loses a launch race connects to the winner. A status 3 from `daemon run
--stdio` therefore comes only from an older pin's attached runtime ("Compatibility"
above), whose runtime lock was held. The editor maps each status, and an
older pin's, to its Runtime-line note and follow-up (§19.16 "Through the
relay"); a status is only meaningful when the relay exits before forwarding
`welcome`.

### 19.11 Lifetime

*Status: master (`daemon/server.lua`, `daemon/command.lua`). A `lw` command
connects for a moment (handshake, `ping`) and leaves; the keepalive rule
applies to every authenticated connection, except one that owns a running
operation (§19.15). A running build makes the daemon busy (handle `busy`); a
`retire`d daemon exits when no connection is busy (§19.9 "Busy",
`Server:_retire_idle`, step 5g.3).*

- **Attached clients keep it alive.** A connection counts while authenticated
  and open. The editor sends a keepalive `ping` (about every 30 s); a
  connection silent for three intervals is dropped as half-open.
- **Observers and retirement.** A `retire`d daemon broadcasts `retiring` to
  every connected observer (§19.16), and `welcome` carries `retiring` for one
  that connects later; an observer then disconnects and does not reconnect to
  that daemon. A retiring daemon exits once **no connection is busy** — none
  owns a running task or has a request in flight (§19.9 "Busy"); a connection
  that only observes or subscribes, or an idle client still connected, never
  holds it off. (Every connection still counts for the idle timeout and in
  `clients`.) A request left in flight for a long time (10 minutes) is noted
  once in the runtime log, never cleared: it keeps its connection busy.
  `status` reports `observers`, the number of observer connections, and
  `tasks`: one `{ task_id, name, kind, profile, units, origin, started_at,
  percent? }` per running task — its `start` meta (§19.15), the wall-clock
  time it started, and its last progress percent, absent before the first
  tick. An addition to the frozen `status` shape (§19.8): a daemon of an
  older protocol omits it.
- **Idle exit.** Idle — **no connections and no background work** — for the
  idle timeout (setting `daemon-idle-timeout`; default the idle grace
  `IDLE_GRACE_SECONDS`, 45 seconds, from step 5r — 1 hour before it, see
  "Warm restarts" below), the daemon exits. The idle clock starts when the last connection closes or the last
  background work ends, whichever is later; the handle's `idle_since` is
  absent while background work runs. *(Step 5i, `Server:lifetime`.)*
  **Background work** is work the daemon owns with no connection as
  owner — tool detection, scans, the `compile_commands.json` refresh,
  housekeeping; today the loaded model's tool detection (a `snapshot` or
  `query` load does not wait for it) and a run still settling after its
  owner left or its task ended (a cancellation, a reset's deletion).
- **Background work cap.** Background work has a maximum duration,
  `BACKGROUND_MAX_DURATION` (10 minutes), after which it is stopped (and,
  from step 5r, its interrupted part is not written — "Warm restarts"
  below). The clock counts only
  while the work is ownerless and no connection is open: it starts when the
  last connection closes or the work starts, whichever is later, and a
  connection opening resets it. Past the cap:
  - **Tool detection** cannot be cancelled (it has no handle): it is
    abandoned — with no run active, the daemon unloads the model, so the
    late result is dropped (a torn-down model never applies it, so no
    workspace file records it); the probe subprocesses run to completion on
    their own. The CLI's machine-level tool cache (`tools.json`, §16), which
    a detection fills when it completes, may still record that late result once it
    completes — it is a complete detection, not an interrupted part. The
    next request loads the model afresh.
  - While a request is being processed (a model segment is running, e.g.
    waiting for the model to load for a client that has since gone), the
    cap does not act; it acts on the first lifetime check after the
    segment ends.
  - **A run** still settling — a cancellation killing its step, or a
    reset's deletion — is stopped as on any stop: the daemon stops (it has
    no connection), through the same path as every exit (§19.15) — a
    deletion stops between entries and its cache entries stay `unknown`
    (an entry is reset only after its tree was removed), the run's locks
    are released, the task ends. Background work that can be neither
    abandoned nor stopped otherwise stops the daemon the same way.

  *(Step 5i, `Server:lifetime`, `Service:abandon_background`,
  `Service:in_segment`.)* The
  daemon's lifetime never depends on any client's lifetime: a client keeps
  it alive only through an open connection.
- *(Step 5r: idle grace B, tool cache C, idle deadline D.)* **Warm restarts.** A script running several `lw`
  commands in a row pays one cold start, and a restarted daemon reuses what
  an earlier one already worked out:
  - **Idle grace.** The default of the idle timeout above is the named
    constant `IDLE_GRACE_SECONDS` = **45 seconds**, defined once (the
    runtime's settings code; every other default refers to it). It replaces
    the former 1-hour default; it is not an extra phase before or after the
    idle timeout. The `daemon-idle-timeout` setting still overrides it
    (e.g. `1h`); an invalid value falls back to the grace. An attached
    editor is unaffected: its connection and keepalive keep the daemon
    alive, so only the gap after the last client goes away shrinks.
  - **Idle deadline** *(part D)*. The `status` reply carries
    `idle_timeout`, the idle timeout in effect in seconds, and — when
    nothing but the asking connection keeps the daemon up (no other client,
    no run, no background work) — `idle_deadline`, the wall-clock time
    (epoch seconds) at which the daemon exits if the asker closes now and
    no client connects: the asker is a connection, so its close restarts
    the idle clock, and the deadline is that close plus the timeout. Both
    are additions to the frozen `status` shape (§19.8): a daemon of an older
    protocol omits them, and a client ignores fields it does not know.
    `lw daemon status` shows them on an `idle` line —
    `timeout 45s, exits at 14:03:12 (in 45s) unless a client connects`, or
    `timeout 45s, idle timer not running (<n> other clients | an operation
    is running | background work)` — and no line for a daemon that does not
    report `idle_timeout`.
  - **Persisted background results.** In step 5r the only background result
    is **tool detection**; scans, the `compile_commands.json` refresh and
    housekeeping are not daemon background work yet, and each defines its
    own unit and fingerprint when it becomes one. Tool detection is persisted
    in the machine-level tool cache `tools.json` (§16.43) — never in
    `loomworks.cache.json`, which keeps no tool results and whose entries are
    the source of build directories for deletion. The unit is the **module
    type**: each type's result is written with a timestamp and the
    fingerprint of its inputs (§16.43: the `lw` identity including its
    `lw_version`, the normalized search path, `PATHEXT`, the platform, the
    module id and module interface version, and the modification time of
    each search-path directory), so a retired daemon's results are never
    reused by a daemon of another version.
  - **Written per type, atomically, on completion.** A module type's result
    is written as soon as its detection finishes, to a uniquely named
    temporary file renamed over `tools.json` (§16.43). An **interrupted
    part** is a module type whose detection had not finished when the work
    ended — the daemon stopped (`lw daemon stop`, a retirement, the root
    removed, the lock lost) or the work was abandoned at the maximum
    duration above — and it is not written; types that finished before stay
    written. (Idle exit never interrupts background work: the daemon is not
    idle while background work runs.) A type that finishes after its work
    was abandoned is a complete result and may still be written, as above.
  - **Reuse on start.** On the next load the daemon reuses each module
    type's cached result whose fingerprint matches the current inputs and
    detects only the other types; a load whose types all match runs no
    detection, so no background work follows it. There is no time-to-live: a
    fingerprint mismatch reruns only that type, and `lw tools` rescans every
    type (§16.43).
  - **Limits.** Several writers (daemons of other workspaces, in-process
    `lw` commands) share `tools.json`; two that write at the same time can
    lose one of the updates, which costs only a later re-detection of that
    type. On Windows a rename blocked by another process (a reader, an
    antivirus scan) loses only that cache write. Neither ever leaves a torn
    `tools.json`.
- **Root removed.** On each heartbeat the daemon checks its workspace root; if
  it is gone, it cancels running tasks and exits.
- **Lost lock** — §19.2.
- **Exit** of any kind cancels running tasks (their clients see the
  cancellation of §19.15), releases operation locks and the runtime lock,
  removes the handle and (POSIX) the socket, and ends the process — no timer or
  handle may keep it alive.

**Commands.** `lw daemon status` reads the handle and lock and, for a live
same-host daemon, asks it for `status` (clients, running operations, versions,
from step 5r the idle timeout and deadline — "Warm restarts");
it never launches. `lw daemon stop` sends `stop` (the daemon exits as above)
and waits (about 10 s) for the runtime lock to be released; it never kills —
a daemon that does not stop in time is reported as not responding, with
`lw daemon stop --force` as the remedy. A daemon still starting (it holds the
runtime lock, its handle is not published yet) is first given the same
window to publish its handle — a slow start on a loaded machine is not "not
responding". A daemon whose handle's `key_id` (§19.6) is not this lw's is
not asked: `lw daemon stop` says it belongs to another loomworks data dir
(different key) and exits 1 without connecting; one that does not prove this
lw's key in the handshake is reported the same way (it belongs to another data
dir or is not a loomworks daemon), and nothing more is sent to it. `lw daemon
stop --force` and
`lw daemon kill` are the forced recovery of §19.5. Stopping when no daemon runs
succeeds with nothing to do. A daemon on another host is never stopped or
killed from here (the command names the host); a stale one is reclaimed per
§19.5. `lw daemon restart` is stop then launch (`--force` applies to the
stop). None of these require the
workspace to load. `lw daemon list` and `lw daemon stop --all` /
`kill --all` act on every daemon of this user on this host (§19.6.1).

### 19.12 Wire identity and change broadcasts

*Status: master for the coarse `model_change` broadcast (`daemon/server.lua`
`model_changed`, sent after each committed write of a state file by the
daemon — the working copy or the cache, `Workspace:_record_written`), whose
client re-reads the files (§19.16), and for the opaque-id registry and the
current-key → id index (`daemon/snapshot.lua` `registry`, `index`; carried in
a snapshot, §19.13); the id-keyed broadcasts and the re-pull protocol #88.*

**Step 4 form.** `model_change { seq, session_generation }`: `seq` advances by
one per broadcast within a session. The editor, which still loads the
workspace from disk itself, answers it by applying the change to its files at
once — its file tracker's pending-change delivery (§2, the same reload the
poll would make a moment later) — rather than re-pulling a snapshot. A
broadcast at or below the last `seq` of the same session generation is
ignored; a new generation is always applied.

The daemon keeps a session-local **opaque-id registry** keyed by object
identity: an id is assigned once, survives renames (it follows the object, not
its key) and refreshes (the deserializer reuses a matching object), is never
reused within a session, and is discarded on restart (a new session
generation). An id is an opaque string that carries the session generation,
so an id cached from an earlier session never names an entity of this one:
it is a stale reference, refused (§19.20 "Errors and domain results"), never
resolved to whatever entity the new session numbered alike. Snapshots carry
a current-key → id index from which a client builds its id↔key map, a
transport-layer router that domain logic never consults. *(Step 5g.2 part B
changed the index's ids from integers to these strings, in the protocol-10
`snapshot` reply too — deliberately: nothing reads them yet, and they share
the registry with the interfaces' ids.)*

Every model change advances a per-workspace sequence number and broadcasts a
typed `model_change` stamped with seq and session generation to every
authenticated client. A client re-pulls the affected scope snapshot (coarse
invalidation); a broadcast at or below its seq is ignored, a newer one
arriving mid-refresh schedules exactly one more re-pull, and a new session
generation forces a full re-hydrate. Per-object deltas are a future
optimization.

**Ids on the interfaces.** *(Step 5g.2: the `changed` signal (part A) and
references in requests (part B: the operations' interfaces and
`Profiles/1.compiler_cache`; ids are opaque strings carrying the session
generation) are implemented; records
of further interfaces land with the steps that land them, §19.19.)* Ids are the only entity handles on
the wire: there are no remote object references, proxies or lifetimes. Every
entity record in an interface result or signal (§19.20) carries its `id` from
this registry and its `key` / `label` for display; a request names an entity
by a reference that is either `{ id }` or `{ key }` (§19.20). `model_change`
becomes the `changed { seq, session_generation, scopes? }` signal of
`loomworks.Workspace/1`, delivered to its subscribers under the same
generation rule. An interface signal's `seq` counts per object **and
connection**, over only the signals actually sent to that connection: it is
gapless for that connection, so a gap means a lost signal and the client
fetches the state again (the `model_change` broadcast's per-workspace `seq`
above is the protocol-10 form). A connection of protocol 10 (v0, §19.8) keeps
receiving the `model_change` broadcast unconditionally.

### 19.13 Snapshot and projection

*Status: master for the `snapshot` request, the projection builder and the
`welcome` header (`daemon/snapshot.lua`, `daemon/service.lua`
`on_snapshot`, `workspace.assemble_snapshot`; protocol 10); the read-only CLI
commands read a projection in `daemon` mode (`cli.lua` `read_workspace`,
§19.1). Re-pulls on `model_change` and the view-scoped model future.*

The daemon is model-authoritative; a client keeps a **projection** for
rendering and integration. The client builds it with the **same deserializer**
the on-disk loader uses, fed by the wire instead of the disk: the daemon sends
the three file-shaped tables (published baseline, working copy, cache) plus
the resolved toolchain detection. Serializing the daemon's model and the
client's projection yields identical bytes (§19.17).

Consumers pick one of three strategies: an **always-warm header** (active
profile, workspace name, error state — carried in `welcome` and kept fresh by
broadcasts, so a status-line redraw never queries); a **view-scoped model**
(the status page hydrates a scope snapshot on open, follows broadcasts, drops
it on close); and **transient queries** (pickers and commands query, act,
discard).

**`snapshot` request.** `snapshot { scope, env }`: `scope` is `all` (the
default), `config`, `user` or `cache`; `env` is the requesting client's
environment, as for a routed operation (§19.15). A loaded model is served as
it is, whatever the requester's environment: a snapshot never reloads it,
runs no file check and waits for no tool detection. With no model loaded the
daemon loads it in the requester's environment, without waiting for tool
detection (it goes on in the background). The reply is `ok` with
`outcome = "ok"` and:

- `config` (scope `config`): the published baseline as the daemon loaded it
  from `loomworks.json` (parsed, program-bearing fields stripped, §17.6);
- `user` (scope `user`): the working copy as the model serializes it for
  `loomworks.user.json`, with its schema `_meta`;
- `cache` (scope `cache`): the cache as the model serializes it for
  `loomworks.cache.json`, with its schema `_meta`;
- always: `tools` (the toolchain detection the model holds, as tool rows:
  module type → list of `{ key, label, tool_data }`, `key` absent for a
  module whose single toolchain has none; the same shape as the `tools`
  query, §19.14), `shared_ignored` (the stripped program-bearing fields,
  §17.6), `index` (the semantic-key → id index of §19.12: `projects`
  project key → id, `config_sets` name → id, `profiles` profile key → id,
  and `config_units` a list of `{ project, configuration, id }` by project
  and configuration key; an unchanged model keeps its ids across
  snapshots), `seq` and `session_generation`.

A scope the request does not name is absent. A workspace the daemon cannot
load is answered `outcome = "refused"` (`message`), and a request it does not
carry (stopping, malformed, another environment while a build runs)
`outcome = "declined"` (`reason`), as for a routed operation. A snapshot takes
no lock, starts no task and writes nothing to a loaded model; the load it
triggers when none is loaded is the ordinary workspace load (it may complete
a commit journal, §19.4). A client builds its projection
from a snapshot of scope `all` through the deserializer of the on-disk load,
fed these tables instead of the files' bytes (their signatures are not
re-verified: the wire is authenticated). A projection is read-only: it never
saves the working copy or the cache, and it watches no files.

**Header.** `welcome.header` carries `root`, `pid`, `lw_version` and
`session_generation`, plus the model's `state`: `loaded` with the
workspace's `name` and `active_profile` (the active profile's key, absent when
none); `error` or `refused` (a trust, newer-schema or journal refusal) with
the load failure's `error` message; or `unloaded` before the daemon loaded the
workspace. Sending `welcome` never loads the workspace.

**As interfaces.** *(`lw.internal.Snapshot/1` and
`loomworks.Workspace/1.header`: implemented, step 5g.2 part A
(`daemon/core_interfaces.lua`); the CLI's read commands call
`Snapshot/1.get` over transport 11 since part B (`daemon/calls.lua`); the
editor views steps 5j–5n, §19.19.)* The `snapshot` request becomes `lw.internal.Snapshot/1.get { scope }`
(§19.20), flagged `same_build`: the CLI's read commands and the parity tests
use it, the editor never does, and `snapshot` stays as its v0 alias. The
always-warm header is the `loomworks.view.Header/1` interface (and
`loomworks.Workspace/1.header`); `welcome.header` stays as it is, frozen.
View-scoped models are `loomworks.view.*` interfaces, one per view, each
returning its full state on subscribe (`initial`, §19.20) and following with
`update` signals, so a reconnect re-hydrates with no further protocol; the
editor's projection of file-shaped tables is replaced by these views as the
steps land.

### 19.14 Commands

*Status: #88 (mutation commands); the set of commands grows per §19.19.
Master for the `query` request with the `tools` and `profile_cache` queries
(`daemon/snapshot.lua` `QUERIES`, `daemon/service.lua` `on_query`; protocol
10); `lw health` still probes in-process.*

A mutation is a **command** the daemon applies to its model with the
operation's locks (§19.3) and persists. Commands are FIFO-serialized: a
command's `model_change` broadcast precedes any later command's and precedes
its own acknowledgement, which carries only the outcome (`ok`, `rolled-back`,
`partially-applied`) or an error. Wire arguments (semantic keys) are resolved
to domain objects at the serialization boundary; domain logic stays
reference-based.

Read-only queries run on the client's projection, except queries that probe
the host (health, tools, sdk detect, profile query), which are `query {name,
args, env}` requests run in the client's environment. `name` names a query of
the daemon's registry, `args` (an object, default empty) its arguments, and
`env` the requesting client's environment, which the query runs in (a model
segment, §19.15). The reply is `ok` with `outcome = "ok"` and `result` (the
query's JSON object); `outcome = "refused"` (`message`) for an unknown name, a
failed query or a workspace the daemon cannot load; `outcome = "declined"`
(`reason`) as for `snapshot`. A query is read-only: it changes neither the
model nor any file, and it runs against the model as it is (loaded as for
`snapshot` when none is), never unloading it for another environment. The
registry starts with `tools` (the toolchains each module type detects in the
client's environment, detected once per query: `result.tools`, tool rows as
in a snapshot's `tools`, §19.13) and `profile_cache` (`args.profile` and
`args.project`, keys: `result.cache`, the compiler cache that profile
resolves for that project, as fields `{ policy, tool?, path?, present,
stale, msvc_auto_off, applicable, not_applied_reason?, not_applied_hint? }`
that the client formats as `lw profile query … cache` prints it; `cache`
absent when that project's module does not cache C/C++).

**As interfaces.** *(The query registry: implemented, step 5g.2 part B
(`Toolchains/1.list`, `Profiles/1.compiler_cache`; the CLI calls them over
transport 11); command methods: plan, step 5o, §19.19.)* Commands are the **mutating methods** of the model
interfaces (`loomworks.Workspace/1`, `Profiles/1`, `Projects/1`,
`ConfigSets/1`, `Sdks/1`, `Maintenance/1`; §19.20), declared mutating in their
schemas, with the rules above unchanged: FIFO, the `changed` signal (and the
affected views' `update`s) before the acknowledgement, outcome `ok`,
`rolled-back` or `partially-applied`. The query registry becomes interface
methods — `tools` is `loomworks.Toolchains/1.list`, `profile_cache` is
`loomworks.Profiles/1.compiler_cache` — and `query { name }` stays as their v0
alias. Wire arguments that name entities are references (`{ id }` or
`{ key }`, §19.20): the editor sends ids, the CLI the keys the user typed,
resolved with the same messages and exit codes as in-process (§16.9).

### 19.15 Task stream and delegated operations

*Status: master for `lw build` in all its forms (`lw build [<profile>]
[--target <name>]… [--force] [--reconfigure] [-v] [-- <args>]`) in
`runtime-mode daemon` (`daemon/service.lua`, `daemon/runner.lua`,
`daemon/tasks.lua`, `daemon/envscope.lua`; the client in `cli.lua`
`_delegate`), and for the batch form of `lw test` (`lw test [<profile>]
[--junit <file>] [-- <args>]`, §16.16; `lw test --target` stays in-process,
see Routing), and for the preparation of `lw run` (§16.17; see Run;
`run_prep.lua`, the client's `_finish_routed_run`; device runs stay
in-process, see Routing), and for `lw clean [<profile>]` (§16.1; see Clean;
the plan, lines and wipe shared with the in-process clean in `build_run.lua`,
the wipe the in-process build-directory deletion `Workspace:clean_wipe_build_dir`
with a stop predicate); observed by the editor (§19.16);
`lw reset [<profile> | --all] [-y]` (§16.30; see
Reset, step 5d); other operations future. The task-streamed interface
methods ("Tasks of interface methods" below: `Build/1`, `Tests/1.run`,
`Launch/1.prepare_run`) are implemented, step 5g.2 part B, and the CLI calls
them over transport 11; `loomworks.Tasks/1` observation signals, `list` and
`cancel` are implemented, step 5g.2 part A.*

A running operation streams `task` events on a **task stream**, separate from
model changes and observable by every connected client (a build started by the
CLI streams into the editor): `start` (`meta = { name, kind, profile, units,
origin }` — `profile` the profile's key, `units` one `{ project, configuration }` per
project of the profile, the project key and its configuration unit's key;
semantic keys, which a client resolves to its own domain objects at the
boundary, §19.14; `origin` the owner's `hello.client`, `cli` or `editor`,
set by the daemon, never taken from the request), `line` (one of loomworks's own lines —
a status line on standard output, a note on standard error), `output` (a
step's raw bytes, `stdout` or `stderr`), `progress` (coalesced: a tick only
when the integer percent advances) and `done` (`exit_code`, and the refusal or
failure the client prints as `lw: <error>`). The client that started the task
— its **owner** — receives every event, unbounded and in order: the stream is
its terminal. It is **flow-controlled**: when a few megabytes wait unread on
the owner's connection (a client that stopped reading, e.g. `lw build | less`
paused), the daemon stops reading the running step's output until the owner
caught up, so the build tool then blocks on its full pipe as it blocks on a
paused terminal in-process, and the daemon's memory stays bounded. Up to that
bound (about 4 MiB) the output is buffered, so a reader paused briefly does
not pause the tool — a build whose whole output fits finishes while the reader
waits, and the reader still gets all of it, in order;
cancellation still applies while paused. Other clients **observe** it with
output bounded per task by bytes (a few megabytes each, then a single
truncation notice); an observer whose connection falls further behind than a
bound is disconnected (it connects again to re-attach) — unless it owns a
running operation itself, which then only misses observed events. Model changes are never dropped; the durable
outcome arrives as a `model_change` (§19.12).

**Request.** `build { args, interactive, env, command }` — `args` carries the
parsed command line (`profile`, `targets`, `extra`, `force`, `reconfigure`,
`verbose`). The reply's `outcome` is one of:

- `accepted` (`task_id`, `profile_key`, `pid`) — the build runs as a task owned
  by this connection;
- `refused` (`message`, `exit_code`) — before any side effect: the workspace
  is refused (§17.4, a journal it cannot complete §19.4, a newer schema §2.7)
  or the profile argument does not resolve (§16.9). The client prints it as
  the in-process host does and exits with that code;
- `declined` (`reason`) — before any side effect: the daemon does not carry
  this request; the client runs it on the in-process path. It declines the
  interactive onboarding of a profile from a configuration set (prompts,
  §16.9) and a request in a different environment while another build runs
  in it (see Environment).

`test { args, interactive, env, command }` — the batch form of `lw test`
(§16.16) — has the same outcomes; `args` carries `profile`, `junit` (the
`--junit` path, made absolute by the client against its working directory, as
the in-process host does) and `extra` (the arguments after `--`, for the
native test runner). It is also `refused` when the profile builds with a
foreign kit (§18.6, the in-process refusal pointing at `lw test --target`).
Its task's `meta.kind` is `test`. In this section "build" stands for either
operation unless a rule names one.

**Same behaviour.** An operation run in the daemon is behaviorally identical to
the in-process operation it replaces — the same step sequence, locks, gates,
status lines, cache write-back, failure lines and exit codes — differing only
in how a step is spawned (streamed) and how a refusal travels (on the stream,
printed by the client exactly as the in-process host prints it). For a build
this is the shared build-step sequence of §16.4 / §16.6 / §16.28 / §5.1 / §5.10:
the build-directory locks of §16.6 taken up front in canonical order with the
§19.5 record (holder kind `daemon`, the operation rewritten configure → build),
a dead holder's lock reclaimed with the interrupted step's state recovered,
the build gate, the artifact-conflict gate (`--force`), the full-reconfigure
reset, the configure record and the cache write-back under the save guard
(§2.7 — a refused save ends the build with its message, as in-process), the
failure line with the `--target` hint, and `BUILD OK: <profile>`. Only the
build tool's own terminal detection differs: its output reaches the client
through a pipe, as when the in-process build is piped (`lw build | tee`) — so
a tool that colours or redraws only on a terminal does not (ninja prints every
`[n/N]` line instead of one updating status line, compilers drop colour). No
colour variable is added for it: such variables (`CLICOLOR_FORCE`, …) reach
every process of the build, including ones whose output a build script
captures, so they would change what a build does; a user who wants colour sets
them in the environment of `lw build`, which the step receives.

For a test run it is the sequence of §16.16: the build-directory locks taken
as for a build and held across the build AND the test runs (a native runner
may rebuild), the build steps above in their for-test form (a unit whose
runner rebuilds itself is not built separately; no steps → no `building
profile:` line), the units' targets parsed, then one `==> [test] <name>` line
per native runner, every runner run even after one failed, its JUnit file
materialized at the requested path (a warning line when the runner wrote
none) and `JUnit: <path>` lines, and finally either `no tests to run for
profile '<p>'…`, `TESTS OK: <profile> (<n> run[s])`, or the failure `<k> of
<n> test run(s) failed: <names>` with exit 1. A build step that fails ends the
test run as it ends a build.

**Run.** `lw run` (§16.17) is split: the daemon **prepares** the launch, the
client **executes** it. The program is the user's own — interactive,
possibly long-running, attached to a terminal — so it never runs in the
daemon.

`prepare_run { args, interactive, env, command }` — `args` carries the parsed
command line: `profile` and `target` (the operands, §16.17; no `target` for
the default target), `project` (`--project`), `kind` (`--target` /
`--launch`), `cwd` (`--cwd`, sent as given: the launch resolves it as
in-process — variables expanded, relative to the workspace root), `extra` (the arguments after `--`), `no_build` (`--no-build`, also
set by `--dry-run`), `quiet` (`--print` / `--dry-run`) and `prefix` (true when
`--prefix` is given). The wrapper itself and the report format stay with the
client and do not change what is prepared; `prefix` only lets the daemon
refuse a device target, after the validity gate and before deploy, with the
in-process `--prefix cannot wrap a device target …` line. The outcomes are those of `build`; it is also `declined` for a
profile with a foreign kit (see Routing). An accepted request runs as a task
(`meta.kind = run`) that does, and prints, exactly what the in-process run
does before its `running …` line, in the same order:

1. unless `no_build`, the profile's build: the build-directory locks taken as
   for a build, the build steps above (every gate and line), then the locks
   **released** — as in-process, they are held for the build only;
2. the launch target resolved against the built tree (§16.17, "Launch target
   selection": the named target, else the default target, else the sole
   launchable one; the same messages for none, ambiguous and unset) and its
   validity gate;
3. unless `no_build`, the deploy steps (§8), after the locks were released,
   as in-process;
4. the launch spec resolved — variables and `${VAR}` expanded in the client's
   environment (Environment, below).

`done` then carries `exit_code` 0 and `launch = { name, cmd, args, cwd, env }`
— the resolved command, its arguments (a command configuration's declared
arguments, then `extra`), the absolute working directory and, in `env`, only
the launch's own contribution over the client's environment (the overrides
§16.17 "Command inspection" reports), never a whole environment — or a
nonzero exit code and the in-process failure line (a failed build, no such
target, a failed deploy, `cannot resolve launch: …`). The task, and every
lock, ends before the program starts; the daemon keeps nothing of the run.

The client then closes its daemon connection and finishes the run as the
in-process host does after resolving: `--print` / `--dry-run` print the
report (with the not-built note); otherwise it prints `running <name> [cwd:
<cwd>]: <argv>` and executes `<prefix> <cmd> <args>` itself — attached to its
terminal (inherited standard input, output and error; on Windows not hidden),
in `cwd`, with its own environment plus `env`, the program resolved on its own
search path as in-process (§5.10). The program's exit status is `lw run`'s.
Under `--print` / `--dry-run` the client writes the whole task stream to
standard error, so standard output carries only the report. Hence:

- **Not the daemon's.** The program is the client's child. It holds no lock,
  task or connection: `lw daemon stop|kill|restart`, a retire for a version
  change and an idle exit never touch it, and it does not keep the daemon
  busy (§19.11). Ctrl-C while it runs reaches it and the client through their
  console, as in-process; Ctrl-C during the preparation cancels the task
  (Cancellation).
- **Concurrent runs.** Any number of `lw run` may run at once. Their
  preparations are serialized by the build-directory locks like any builds;
  their programs are not.
- **A build while the program runs** proceeds, as in-process. On Windows a
  running executable cannot be overwritten, so a build that relinks it fails
  at that step as it does today; nothing is added for it (no lock held across
  the run, no retry, no warning).
- **Terminal.** The program's output never passes through the daemon: it has
  the client's real terminal (colour, size, redraws), unlike the build's
  tools above.

**Clean.** *(Step 5c.)* `clean { args, interactive, env, command }` — `lw
clean [<profile>]` (§16.1: each project's build-system clean on the
profile's build directories; the configuration is kept) — has the outcomes of
`build`; `args` carries `profile`. It is also `refused`, with the in-process
`nothing to clean for profile '<p>' …` line and its exit code, when the
profile has no configured build directory to clean — decided after
resolution and before any lock, as in-process. Its task's `meta.kind` is
`clean`. An accepted request does, and prints, exactly what the in-process
clean does: the build-directory locks of §16.6 taken **exclusive** up front in
canonical order with the §19.5 record (holder kind `daemon`, operation
`clean`; a dead holder's lock reclaimed and its state recovered as for a
build), `cleaning profile: <p>`, one `==> [clean] <name>` line and step per
project, and `CLEAN OK: <profile>`; a failing step ends the task with the
in-process failure line and the step's exit code, the later steps not run.
A **core-performed wipe** (§8.1 `wipe_build_dir`) runs in the daemon process
as the SAME build-directory deletion as in-process (§4.6, §4.7; one path for
both hosts), under the workspace operation lock taken before the
build-directory locks (§19.3): the path is validated first (§4.6: non-empty,
within the workspace root and never the root itself, links not followed, no
command interpreter) — a refused path ends the task with the in-process
`clean refused: unsafe build directory …` line; the clean's units sharing the
directory are one deletion batch; the cache says `unknown` on disk before the
tree is removed and the units are reset only after the removal succeeded; a
directory still used by a configuration outside the clean is kept (the
in-process `kept <dir> — still used by another configuration` line). The
removal does not block the daemon's endpoint (pings, status and other
clients are served while it runs). Cancelling during a wipe stops it between
entries (`clean stopped: <reason>`); what was removed stays removed and the
cache stays `unknown` (never reset after a partial removal, §4.7). The clean
writes the cache exactly when the in-process clean does, and any write-back's
`model_change` precedes `done` (§19.16, End).

**Reset.** *(Step 5d.)* `reset { args, interactive, env, command }`
— `lw reset [<profile> | --all] [-y]` (§16.30: the profile's build
directories, or with `--all` every build directory the workspace knows,
orphaned ones included, removed from disk and their units returned to
`unconfigured`; the profile is kept) — has the outcomes of `build`, plus
`confirm`; `args` carries `profile`, `all`, `yes` (`-y` / `--yes`) and
`plan`. The daemon plans the reset as in-process (§16.30: the directories to
lock, the directories on disk to remove, whether cached state is cleared
without a directory), after resolution and before any lock or side effect,
and then answers:

- with nothing to reset: `refused`, with the in-process `nothing to reset for
  <scope> — no build directories to remove.` line and its exit code 0, and
  `stream = "out"`: printed on standard output as in-process;
- without `yes`: `confirm` (`lines`, `plan`, `profile_key` — absent for
  `--all`; the client names the scope from it in its question and refusals)
  — no lock taken, nothing changed. `lines` are the in-process listing (`Will remove N build
  directories and reset <scope> to unconfigured:` and one line per directory,
  or the line for cached state without a directory); `plan` is an opaque token
  of the planned scope, lock set and removal set. The client prints the lines
  on standard output and asks the user as in-process (Confirmation): a
  non-interactive client prints the in-process refusal naming `-y` and exits
  1; a declined prompt prints `aborted — nothing was removed` and exits 1; a
  confirmed one sends `reset` again with `yes` and that `plan`;
- with `yes` and a `plan`: the daemon plans again; a plan whose token differs
  is `refused` (`the build directories to reset changed since they were
  listed — run lw reset again`, exit 1) before any side effect — compared
  before the nothing-to-reset check, so a listed plan whose directories
  vanished is refused as changed, as in-process — so a reset
  never removes a directory the user was not shown. An equal plan is
  `accepted`, and its task prints no listing (the client printed it);
- with `yes` and no `plan` (`-y` on the command line): `accepted`; the task
  prints the listing first, as the in-process reset does before its deletion.

Its task's `meta.kind` is `reset`; `meta.profile` is the profile's key, or
absent with `meta.scope = "all"` for `--all`; `meta.units` are the planned
units (for `--all` every configuration unit with a build directory; an
orphaned directory has no unit and is not listed). An accepted reset does,
and prints, exactly what the in-process reset does: the workspace operation
lock taken first (§19.3, operation `reset`), then the build-directory locks
of §16.6 for every directory of the lock set, **exclusive**, in canonical
order with the §19.5 record (holder kind `daemon`, operation `reset`; a dead
holder's lock reclaimed and its state recovered as for a build; a held one
ends the task with the in-process refusal naming the holder, nothing
removed). With every lock held and before anything is removed, the reset
plans again and compares the token with the plan it listed: a directory that
appeared or vanished in between (another process's build that finished and
released before the locks were taken) ends the task with the same `the build
directories to reset changed since they were listed — run lw reset again`,
exit 1, the locks released and nothing removed. The removal is the SAME build-directory deletion as in-process
(§4.6, §4.7; one path for both hosts): each path validated first; units
sharing a directory are one deletion batch; the cache says `unknown` on disk
before a tree is removed and the units are reset only after its removal
succeeded; a directory still used by a configuration outside the reset is
kept, its state cleared for the reset units only; `--all` then removes the
orphaned directories by the same path. The reset then checks that every
removed directory is gone from disk, waiting out a delete-pending directory
for the in-process bound without blocking: a directory still present ends the
task with the in-process `reset failed — N build directories could not be
removed:` lines, a deletion that does not complete with `reset timed out — …`,
both exit 1; success prints `RESET OK: <scope>`. The removal does not block
the daemon's endpoint (pings, status and other clients are served while it
runs). Cancelling during the removal stops it between entries (`reset
stopped: <reason>`); what was removed stays removed and the cache stays
`unknown` (never reset after a partial removal, §4.7); the locks are held
until the removal has stopped and are then released, the operation lock last.
A removal still running after its task ended (timed out) keeps the daemon
busy — it neither idles out nor retires — until it settles, and a daemon that
stops meanwhile asks it to stop between entries.
The reset writes the cache exactly when the in-process reset does, and its
write-back's `model_change` precedes `done` (§19.16, End).

**Confirmation.** A daemon never prompts. An operation whose in-process form
asks the user before acting (a confirmation, a picker) either is `declined`
for that form (profile onboarding, above) or is asked by the client before it
sends the request, the request then carrying the answer. `reset` is the only
routed operation that asks one: the daemon returns what the question shows
(`confirm`, Reset) and the answer travels with a token of what was shown, so
the daemon acts only on the plan the user confirmed.

**Environment.** A routed build behaves as if the client process had run it.
The client sends its **whole environment** with the request; the daemon
applies it to the operation and to nothing else:

- every piece of model work for the request (the live-workspace sync or
  reload, argument resolution, planning, gates, cache write-back) runs with
  the daemon's process environment switched to the client's (on Windows
  keeping `NoDefaultCurrentDirectoryInExePath=1`, §5.10, when the client's
  lacks it) and restored afterwards — so `${VAR}` expansions, tool and program resolution on `PATH`
  and probes the module spawns see the client's values. These pieces run one
  at a time (a FIFO), so two clients never see each other's environment;
- each step is spawned with exactly the client's environment plus the step's
  own variables (§8.1, on Windows replacing a name that differs only in case)
  — never the daemon's launch environment, whose loomworks-internal variables
  (`LOOMWORKS_LUA`, `LW_ROOT`) therefore do not leak into builds;
- the daemon's workspace model is kept for the environment it was loaded in:
  a request whose environment differs reloads the workspace from disk first,
  as an in-process load in that environment would read it; while another
  build runs in the daemon, such a request is declined instead. The
  comparison ignores variables that differ between two commands of one shell
  (`_`, `PWD`, `OLDPWD`, `SHLVL`) and between two terminals of one user — the
  terminal's, multiplexer's, SSH and login session's per-window/pane/session
  identifiers (`WT_SESSION`, `TERM_SESSION_ID`, `TMUX`, `TMUX_PANE`, `STY`,
  `WINDOWID`, `SSH_CONNECTION`, `SSH_TTY`, `SSH_AUTH_SOCK`, `GPG_TTY`,
  `XDG_SESSION_ID`, editor terminals' IPC handles `VSCODE_*`, …; names compared
  case-insensitively on Windows), and the hidden `=`-prefixed entries of a
  Windows environment block (cmd.exe's per-drive directories `=C:` and
  `=ExitCode`, which every process started from a cmd.exe — a `.cmd` shim, a
  PowerShell or developer prompt opened from one — inherits); these still
  reach the step unchanged, and the `=` entries are never applied to the
  daemon's own process environment. It is a
  list of what to ignore, not of what to compare: what a load reads is
  open-ended (`${VAR}` references, module and SDK probes, compiler and
  `vcvarsall` variables), and a variable missed by a list of what to compare
  would build with a model read in another environment.

The whole environment is sent because a subset cannot be chosen safely:
compiler, SDK and `vcvarsall` variables (`INCLUDE`, `LIB`, `WindowsSdkDir`,
`VCToolsInstallDir`, …), cache tools and `${VAR}` references in the
configuration can use any name, and an in-process build inherits them all.
It may contain secrets; it never leaves the machine: it is sent only after
the mutual authentication of §19.8, over the owner-only endpoint of §19.7, to
a process of the same user, is held in memory for the request only, and is
never written to the runtime log, the handle or any workspace file. The
client's working directory is not sent: the client resolves the workspace
root, and every step runs in its own absolute directory (the step's, or the
root) on both paths.

**Live workspace.** The daemon loads its workspace on its first operation
(the same load as the in-process path) and keeps it. Its file tracker does
not poll: before accepting each operation the daemon applies every pending
external change to its files exactly as its file watcher would — including a
trust refusal (§17.4), which unloads the workspace and is returned as
`refused` — completes or refuses a commit journal by reloading (§19.4), and
waits for a tool rescan a changed `loomworks.json` started. It then resolves
arguments as the in-process host does (§16.9; the same matcher, the same
messages, the client's interactivity).

**Cancellation.** An operation belongs to its client. When that client
disconnects (`lw` ending on Ctrl-C — see Task ownership for when that is —
drops the connection, which is the cancellation, and exits 130), the daemon stops (`lw daemon stop`, idle,
retire, root removed, lost lock), or the workspace or the operation's subject
is unloaded/removed, the daemon terminates the running step's process tree
(identity-verified by process id and start time, §19.5), records nothing for
that step, releases its locks and ends the task nonzero (`build stopped:
<reason>`; `test stopped: <reason>` for a test run; `run stopped: <reason>`
for a run's preparation; `clean stopped: <reason>` for a clean; `reset
stopped: <reason>` for a reset). A client that loses the connection after its operation was
accepted reports a failure; it never re-runs the operation another way (for a
run: it starts no program). Cancellation ends with the task: a run's program,
started after it, is never the daemon's to stop (Run). A
connection that owns a running operation is never dropped for silence
(§19.11); the CLI also pings while it waits. The step's processes are the
daemon's, not in the client's console, so the interrupt must reach the
client itself: on Windows a routed client re-enables the console's Ctrl-C for
its process (a process started with it disabled — `start /b`, a new process
group, as Git Bash starts the native program it then signals with `kill
-INT` — would otherwise never see it, while in-process the build's own
processes in that console still stop).

**Task ownership.** *(Step 5i: the CLI's two-stage Ctrl-C is implemented,
part F — `cli.lua` `_routed_cancel`, the interrupt handler's interceptor.)* Every task a connection starts — build, test, run preparation,
configure, clean, reset — is owned by that connection. When the connection
closes for any reason (a CLI's Ctrl-C, the editor quitting or crashing, `lw`
killed, a `--stdio` relay ending), the daemon cancels its tasks as above.
Other connections only observe: closing an observer never stops a task.
Configure counts as a connection-owned task from step 5i (cancelled when its
connection closes), but in 5i it reaches the daemon only as a step of a
routed build, test or run preparation; a standalone configure is not routed
through the daemon until steps 5j–5o. In the CLI, once the daemon has
accepted the task, the **first Ctrl-C** asks the daemon to stop it
(`loomworks.Tasks/1.cancel`: the daemon stops the running step's process tree
as above — the daemon runs in its own console, so a build never receives the
console's Ctrl-C) and prints one stderr line, `lw: stopping the <op> - press
Ctrl-C again to stop waiting`; `lw` keeps waiting until the task has stopped
(its `<op> stopped: …` line is printed as usual). A **second Ctrl-C** makes
`lw` leave at once, closing the connection, while the daemon finishes
stopping the task. Either way `lw` exits 130 after an intercepted Ctrl-C —
also when the task ended before the cancel landed (the daemon then answers
that there is no running task) and when the connection is lost meanwhile —
and a run's program is never started. A Ctrl-C before the daemon has accepted
the task closes the connection and exits 130 (there is nothing to cancel
yet). A daemon of protocol 10 has no `Tasks/1`: against it the first Ctrl-C
closes the connection, as before. Only Ctrl-C is two-stage: Ctrl-Break, a
closed console, a hangup and a termination request end `lw` at once
(closing the connection). An attached run (§19.1 "Loopback": the runtime is
the `lw` process itself) is unchanged — a Ctrl-C ends it. *(Future, not
planned in a step: `lw build --detach` hands a task over to the daemon, which
then owns it with no connection.)*

**Tasks of interface methods.** *(Step 5g.2: `loomworks.Tasks/1` — `list`,
`cancel`, the `started` / `ended` signals with the `task_id` filter — is
implemented, part A; the task-streamed methods (`start.meta` naming the
method, `done.result`), part B; the observation bound to the subscription,
step 5g.3 (`tasks.lua` `Task:_observes`).)* The task stream is a
**transport** mechanism (§19.8), not part of any one interface: a method its
schema declares task-streamed (§19.20) — `Build/1.build`, `Tests/1.run`,
`Launch/1.prepare_run`, a module's log stream — replies `accepted` with a
`task_id` and then streams `task` frames with the phases, ownership, flow
control, observer bounds and disconnect-cancellation above. What the
interface types is the payload: `start.meta` also names `object`, `iface`, `v`
and `method`, and `done` carries `result`, validated against the method's
task result schema (for `prepare_run` the launch spec, for a test run its
structured results: `steps`, one `{ name, exit_code, status }` per test step
run, and the `junit` files written; per-case results come later as an
optional field). The outcomes of the operations (`accepted`, `refused`,
`declined`, `confirm`) are unchanged; they are domain results of the method,
not errors (§19.20).

- **Observation** is by subscription: a connection subscribed to
  `loomworks.Tasks/1` on `/tasks` (optionally for one `task_id`) receives its
  `started` / `ended` signals and the frames of the tasks it matches, bounded
  as for an observer above. A connection of protocol 10 keeps receiving every
  task's frames as today.
- **Cancellation**, besides the disconnect above, is
  `loomworks.Tasks/1.cancel { task_id }`, allowed for the task's owner only;
  any other connection gets the error `forbidden`.
- `loomworks.Tasks/1.list` gives the running tasks to an interface client;
  `status.tasks` (§19.11) stays as it is, frozen.

**Routing.** A client routes an operation to the daemon only when the daemon
carries every argument form the client was given; any other form runs on the
in-process path (transition) and a workspace the machine would refuse (§17.4)
is never routed. For `lw build` in step 3: routed in `runtime-mode daemon`
when this command has a matching daemon (it was used, launched or restarted
by the version handshake, §19.9/§19.10), the arguments parse, and the working
copy and cache verify; **not routed** — the in-process path exactly as
before — with `--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI` (§19.1),
`--break-locks` (its ask-and-kill recovery stays with the client process), a
version bypass, a daemon that is hung, starting, foreign or could not be
started, and an argument `cmd_build` refuses (it reports it). In
`runtime-mode daemon`, a build the daemon does not run is never silent:
except for the explicit opt-outs (`--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI`)
and the cases the in-process path itself reports (an argument `cmd_build`
refuses, a workspace the machine refuses), exactly one line on standard error
says why, and the build runs in-process. The version handshake's and the
launch's lines (§19.9, §19.10) are that line for a version bypass, a newer
daemon, and a daemon that is hung, still starting or could not be started; a
declined request prints `lw: the workspace daemon declined the build
(<reason>); running without it`; a runtime held by an attached lw command is
waited for, or the build fails "workspace busy" (§19.2); every other case — a
runtime held by another host, `--break-locks`, a daemon that cannot be reached
or fails before accepting, a failed endpoint check — prints `lw: the
workspace daemon could not take the build (<reason>); running without it`.
While the daemon is opt-in, an accepted build prints one dim line on standard
error before its output — `lw: building through the workspace daemon (pid N)`
— which is removed when the default flips; a refusal prints neither.

*(Step 5e:)* in `runtime-mode daemon`, the attached selections
above (`--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI`, the `no-daemon` setting, a
failed background launch) — `--break-locks` given with one of them included —
no longer run the routed operations in-process: they run them attached, over
the loopback transport (§19.1 "Loopback during the transition"), with the same arguments, refusals
and output. An attached operation prints no `… through the workspace daemon
(pid N)` line and no "running without it" line for its attached selection.

`lw test` (step 5) is routed by the same rules, an argument `cmd_test` refuses
taking the place of one `cmd_build` refuses (device options without
`--target` among them), and its lines name the test: `lw: the workspace daemon
declined the test (<reason>); running without it`, `lw: the workspace daemon
could not take the test (<reason>); running without it` and `lw: testing
through the workspace daemon (pid N)`. Its named-executable form, `lw test
--target <exe>…` (local or on a device, §16.16, §18), is not carried in this
step — its device locks, staging and liveness stay with the client process —
and prints `lw: the workspace daemon could not take the test (--target runs
test executables in this process); running without it`.

`lw run` (step 5) is routed by the same rules for its preparation
(Run), an argument `cmd_run` refuses taking the place of one `cmd_build`
refuses (`--print` with `--prefix` among them), and its lines name the run:
`lw: the workspace daemon declined the run (<reason>); running without it`,
`lw: the workspace daemon could not take the run (<reason>); running without
it` and `lw: preparing the run through the workspace daemon (pid N)` (before
the build's output; on standard error like the others). A run on a device
(§16.17, §18) is not carried in this step — its device locks, staging and the
remote program's liveness stay with the client process:

- a device option (`--device`, `--fresh`, `--timeout`, `--no-wait`, a log
  option; §18.3) prints `lw: the workspace daemon could not take the run
  (device options run the program on a device in this process); running
  without it`;
- a profile one of whose units builds with a foreign kit (§18.1, the kit's
  execution platform — known before anything is built) is `declined` before
  any side effect: `lw: the workspace daemon declined the run (profile '<p>'
  builds for <platform>; device runs stay in this process); running without
  it`;
- a target found foreign only by probing its built artifact (§18.1, no kit
  platform) is known only after the daemon built it: the task ends with
  `exit_code` 0, no `launch`, and `device = true`, before any deploy; the
  client prints `lw: the workspace daemon could not take the run (<name> runs
  on a device in this process); continuing without it` and continues
  in-process from the deploy (deploy → stage → execute, §18.4–§18.5) without
  building again.

The editor's own run and debug launches stay in-process in this step
(§19.16).

`lw clean` (step 5c) is routed by the same rules, an argument `cmd_clean`
refuses taking the place of one `cmd_build` refuses, and its lines name the
clean: `lw: the workspace daemon declined the clean (<reason>); running
without it`, `lw: the workspace daemon could not take the clean (<reason>);
running without it` and `lw: cleaning through the workspace daemon (pid N)`.
It has no form the daemon does not carry. Configuring has no command of its
own: it is a step of the routed build (`lw build --reconfigure` forces it,
§16.4), and runs in the daemon with it.

*(Step 5d.)* `lw reset` is routed by the same rules, an argument
`cmd_reset` refuses (an unknown flag, `--all` with a profile) taking the
place of one `cmd_build` refuses, and its lines name the reset: `lw: the
workspace daemon declined the reset (<reason>); running without it`, `lw:
the workspace daemon could not take the reset (<reason>); running without it`
and `lw: resetting through the workspace daemon (pid N)` — printed when the
reset is accepted, so after the confirmation. Each of the two requests of a
confirmed reset is routed or not on its own: when the second one cannot be
routed (the daemon stopped or was retired while the user answered), the
client says so on the could-not line and runs the reset in-process with the
user's answer, never asking again; the in-process reset plans again and
refuses with the changed-plan line above when its plan differs from the one
shown. It has no form the daemon does not carry.

**Not routed.** These commands touch build directories but stay on the
in-process path in this step; they are not routed commands, so they print no
daemon line, and their cross-process locks (§16.6, §19.3) serialize them with
the daemon's operations as with any other process:

- `lw nuke` — removes the workspace's build state (`.nvim/build/`, the build
  and health caches), taking every build-directory lock first (§19.3);
- `lw device clean` (§16.34) — its device locks and the device's staging stay
  with the client process, as for a device run;
- the editor's own operations, including its clean, delete and configure
  actions (§19.16).

### 19.16 The editor as a client

*Status: master for the observer (§19.19 step 4: `daemon/observer.lua`,
`daemon/remote_task.lua`); the host-binary order of step 5h.1
(`provision/select.lua`, `provision/managed.lua`) and the download, check and
pruning of the plugin-managed `lw` of step 5h.3 (`provision/fetch.lua`,
`provision/sha256.lua`, `provision/cache.lua`), the plugin pin of step 5h.4
(`provision/pinned.lua`, `provision/needs.lua`, `scripts/release/pin.sh`, the
two-stage `release.yml`), the pre-launch probe of step 5h.5
(`provision/probe.lua`, `provision/needs.lua` `problems`), the editor's
retirement of an incompatible daemon of step 5h.5 (`daemon/editor_retire.lua`,
`Observer:_weigh_retire`; channel upgrades are step 5h.5, plan); remote tasks shown as
local ones (Running state, Joining late, End, UI below), the origin marker
and the version-mismatch note (`daemon/observer.lua` `mismatch_note`); commands
and the attached editor future. The interface client ("Interface client"
below): the subscription to `/tasks` and `/workspace` is implemented, step
5g.3 (`daemon/observer.lua` `_subscribe`); the views
and operations steps 5j–5o (§19.19); the connection through the `--stdio`
relay, step 5i PR G: its spec (PR G0) *done*; the relay transport and
lifecycle ("Through the relay" except "Skipping an incompatible daemon",
`--retiring`) PR G1, *done* (`daemon/client.lua` `relay`, `daemon/observer.lua`
`_spawn` / `_on_relay`); the incompatible-daemon policy over the relay
("Skipping an incompatible daemon", retirement only over `via = "relay"`)
PR G2, *done* (`daemon/observer.lua` `_skip`, `_weigh_retire`). From G1 the observer no longer watches the handle or
launches a daemon itself ("Step 4" below marks what G1 superseded). The editor-owned child daemon of the
earlier plan (step 5p) is dropped.*

**End state.** *(Planned, step 5i.)* The editor is a **pure `lw` client**
of the **same daemon as the CLI**. It spawns `lw daemon run --root <root>
--stdio`, which connects to the workspace's shared daemon or starts it first
(§19.10 "Connections"), and speaks the protocol through that relay; it reads
none of lw's internal files to connect, launch or follow a daemon, and holds
a keepalive (§19.11). Only diagnostics may still read them, read-only:
`:LoomworksDaemon status` and `:checkhealth loomworks` may inspect the
handle, the runtime lock and the daemon logs to describe what they find;
nothing they read decides whether, when or to what the editor connects, and
they never write, remove or lock anything there. The relay needs a host
binary ("Host binary" below): with none the editor spawns no relay, stays
in-process, and does not observe a daemon another client started. Its tasks are
owned by its connection, so an editor that quits or crashes leaves no task
running; the daemon itself outlives it under §19.11. Operations move from the
editor to commands in the order of §19.19. When the shared daemon cannot be
started, the editor reports it and runs degraded (step 6b); there is no
private-daemon fallback. The editor never runs the daemon code inside its own
process (the earlier design D8, superseded), nor a child daemon of its own
(the earlier step 5p, dropped).

**Through the relay.** *(Step 5i PR G1; "Skipping an incompatible
daemon" PR G2.)* The editor spawns the relay instead of reading the handle
and the machine key itself; "Launch" and "Connect" below then happen inside
the relay (§19.8 "Relay handshake", §19.10 "Connections"). Before each spawn
it selects the host binary ("Host binary" below, with its pre-launch probe;
the selection may be cached for the session) and runs one of these forms of
`<binary> daemon run --root <root> --stdio`:

- **ordinary** (no further flag): connects to the workspace's daemon or
  starts it. Spawned on workspace load, on `:LoomworksDaemon connect`, on
  `retiring` and after the editor's own `retire`, and once per retirement
  episode after a status 16 ("Following a stopped or retiring daemon
  without relaunching it" below);
- **no launch** (`--no-launch`, §19.10 "No launch"): waits for a daemon and
  never launches one. Spawned after a drop, after a status 10 or 11, and
  after a status 14 whose standard error has no `retiring` line the editor
  can parse;
- **retiring** (`--no-launch --retiring <pid>:<start_time>`, §19.10 "A named
  retiring daemon"): waits for the named retiring daemon to exit. Spawned
  after a status 14 whose standard error names that instance (§19.10
  "Retiring-instance line");
- **skip** (`--no-launch --skip-instance <pid>:<start_time>`, §19.10 "Skip
  an instance"): "Skipping an incompatible daemon" below.

With no host binary the editor spawns no relay of any form and stays
in-process ("End state").

- **The relay process.** The editor spawns a relay hidden (no console window
  on Windows) and **not detached**, with plain pipes for its standard input,
  output and error, the per-user state directory (§19.10) as its working
  directory, and the environment it gives the selected binary for a daemon
  launch. It sets no handshake timeout of its own: each step of a relay is
  bounded inside the relay (§19.10 "Connections"), and the waiting forms
  wait without a bound by design. These rules are normative:
  - The editor **never kills a relay's process tree**. On Windows the daemon
    a relay launched is a child of the relay by parent process id (§19.6.1),
    so a tree kill would take down the shared daemon. The editor ends a
    relay by **closing its standard input** (the relay exits 0, §19.10);
    only when the relay has not exited about 5 s later does it kill the
    relay's own process id — a plain kill, never its tree. That backstop
    timer does not keep the editor alive: at editor quit it never fires. On
    Windows the editor's process job then ends a relay still running; on
    POSIX a relay that ignores EOF on its standard input is orphaned. This
    is accepted (a relay exits on EOF; the backstop is for a hung one).
  - An older pin's attached `--stdio` runtime (a `welcome` without `via`,
    §19.10 "Compatibility") holds the workspace's runtime lock; it is ended
    the same way, by EOF on its standard input, never by a tree kill, so it
    releases the lock and cancels its tasks as a closing connection does.
  - The daemon **never inherits the relay's pipes**: the relay launches it
    detached with no inherited standard handles (§19.10 "Launch"), so the
    editor sees EOF on the relay's standard output when the relay exits,
    whatever the daemon does, and ending a relay never reaches the daemon.
    End-to-end tests check that a daemon started through an editor relay
    survives the relay and the editor, and that no relay is left (`lw daemon
    list`) after teardown.
  - The relay's exit and the EOF on its standard output arrive in either
    order. The exit status is mapped ("Exit before `welcome`" below) only
    when the relay exits before the editor has received `welcome`; after
    `welcome`, any exit or EOF of the relay is a **drop** of the connection
    (the editor ends the relay as above). Before `welcome`, once the relay
    has exited the editor waits about 1 s for the EOFs still missing, then
    maps the status anyway. Once its standard output reached EOF the editor
    waits about 5 s for the relay's exit; a relay still running then is an
    internal error with no exit status — the editor waits with the
    internal-error note, as the "Exit before `welcome`" table's internal
    errors do (a relay that sends anything other than `welcome` first is
    treated the same) — and the editor ends it as above (closing its
    standard input, then the plain kill).
    A relay the editor ended itself (workspace swap, shutdown, a skip relay
    replaced) is not mapped.
  - The relay's last standard-error line is kept for the Runtime line's
    detail.
- It sends its usual `hello` (`client = "editor"`, `role = "observer"`) and
  judges the daemon from `welcome.daemon` exactly as it judges a `challenge`
  today, by the **editor's** compatibility rule (§19.9 "Editor retirement",
  "Retiring an incompatible daemon" below), never the CLI's `lw_version`
  equality: the relay itself applies no version policy, so a relay the editor
  starts never restarts a compatible daemon. The editor's `retire` goes over
  the relay connection, and only when `welcome.via = "relay"`. A `welcome`
  without `via` comes from an attached runtime of an older pin (§19.10
  "Compatibility"): the editor observes it **without the version check**
  (such a `welcome` carries no `welcome.daemon` to judge) and **never
  retires it**.
- **Waiting notes.** A relay reports nothing while it waits (on an attached
  run, a starting daemon, a retiring daemon, or for any daemon at all). Until
  it forwards `welcome` the Runtime line shows one generic note for its form:
  ordinary — connecting to or starting the workspace daemon (naming the
  binary and its source, as for a launch); no launch — waiting for a
  workspace daemon, none is launched (`:LoomworksDaemon connect` starts
  one); retiring — waiting for the retiring daemon to exit; skip — the
  incompatible-daemon note ("Connect" below). A progress line from the relay
  is not part of step 5i (BACKLOG).
- **Exit before `welcome`.** A relay that exits before `welcome` is mapped
  from its exit status (§19.10 "Relay exit status") to a Runtime-line note,
  with the relay's `lw: ...` standard-error line as detail (never the
  status-14 `retiring` line), and a follow-up. "Wait"
  means: the editor stays in-process with that note and spawns no further
  relay until an explicit `:LoomworksDaemon connect` (or a workspace
  reload).

  | Status | Note | Follow-up |
  |--|--|--|
  | 10 | could not start the workspace daemon; the editor runs degraded (step 6b) | one no-launch relay, then wait |
  | 11 | the workspace daemon is not responding | one no-launch relay, then wait |
  | 12 | the daemon belongs to another loomworks data dir, or is not a loomworks daemon | wait |
  | 13 | the workspace daemon runs on another host | wait |
  | 14 | a retiring daemon is still busy | a retiring relay, or a no-launch relay ("Following a stopped or retiring daemon" below) |
  | 16 | the retiring daemon has exited and no other is live | the retirement episode's one ordinary relay, else wait |
  | 3 | the pinned `lw` predates the shared-daemon relay and another runtime holds this workspace (an older pin's attached `--stdio`, §19.10 "Compatibility"); running in-process — update the pin | wait |
  | 1 | an internal error — or, for a repository pinned before 0.1.43-beta.15, the pin redirect's refusal (§16.23 "A pin older than the command"), whose standard-error line names the pinned version and the release that introduced the command; the note shows that line | wait |
  | 2 | an internal error (usage) — or, when the relay was spawned with `--no-launch`, `--skip-instance` or `--retiring`, the pinned `lw <version>` does not support the editor relay flags (update the pin), naming the pinned version | wait |
  | 15 | an internal error (protocol) | wait |
  | 0 | an internal error (the relay ended although the editor kept its standard input open) | wait |
  | any other | an internal error | wait |

  "One no-launch relay" is one per failure: a no-launch relay spawned in
  answer to a status 10 or 11 is not answered with another when it, too,
  exits before `welcome` (it then follows the table's other rows or waits).
  A pinned release that predates a flag the editor passes (`--no-launch`,
  `--skip-instance`, `--retiring`) may answer with a usage status; that is
  status 2 above, and the editor still waits for an explicit
  `:LoomworksDaemon connect`. The note then names the pinned version (from
  `lw.pin`, §16.21) — that the pinned `lw <version>` does not support the
  editor relay flags — with the relay's usage line as detail, so the user is
  not left with a bare usage error. A status 2 from a relay spawned with none
  of those flags is the plain internal-error note.
- **Following a stopped or retiring daemon without relaunching it.** "No
  relaunch after a stop" and "Retiring" below watch the handle, which the
  editor no longer reads once it uses the relay; relays wait inside lw
  instead.
  - **Drop.** When the connection drops (after `welcome`) because the daemon
    stopped, crashed or dropped this observer, or the relay ended, the
    editor reconnects only through one no-launch relay, so `lw daemon stop`
    stays meaningful: the relay connects when a daemon appears, and the
    editor ends it ("The relay process") when it no longer wants one
    (workspace swap, shutdown).
  - **Retiring.** On `retiring` received over a live relay connection, and
    after its own `retire` succeeded ("Retiring an incompatible daemon"),
    the editor disconnects and spawns one ordinary relay, whose own wait
    (`RELAY_RETIRE_WAIT`) covers the retiring daemon and which launches the
    successor. This starts a **retirement episode**.
  - **Status 14.** When a relay exits 14 the editor waits through a relay
    that never launches: a retiring relay naming the retiring daemon, with
    the instance the exited relay's standard error named (§19.10
    "Retiring-instance line": the last line that is exactly `retiring
    <pid>:<start_time>`, the value being the daemon's instance id, §19.5 —
    e.g. `retiring 1234:win:5678`), passed as `--retiring
    <pid>:<start_time>`. Only when that line is missing or unparseable (a
    relay from an older pin, or a daemon without `start_time`) is it a
    plain no-launch relay. A status 14 also starts a retirement episode
    when none is open. Either relay connects to a successor another client
    starts. A plain no-launch relay can miss a daemon that exits before it
    first looks (§19.10 "A named retiring daemon"); it then waits as after
    a stop, until a daemon appears or an explicit connect.
  - **Status 16.** When that relay exits 16 (the retiring daemon is gone,
    no other is live) the editor spawns one ordinary relay, which launches
    the successor — at most **one per retirement episode**. A further 16 in
    the same episode is a note and a wait. The episode, and its count, end
    at the next `welcome` and on `:LoomworksDaemon connect`.
- **Skipping an incompatible daemon.** *(Step 5i PR G2, `daemon/observer.lua`
  `_skip`.)* The editor learns that a daemon is
  incompatible only from `welcome.daemon`, after the relay connected; a new
  relay of either form would connect straight back to it. So when the editor
  does not observe an incompatible daemon — "Incompatible daemon" below,
  including once it declines to retire one it held a connection to ("Retiring
  an incompatible daemon") — it closes that relay, stays in-process, and
  spawns one `lw daemon run --root <root> --stdio --no-launch
  --skip-instance <pid>:<start_time>` naming that daemon from
  `welcome.daemon` (§19.10 "Skip an instance"). That relay never connects to
  it; it connects to a successor once one is live (another client launched
  it after the skipped one exited), and the editor judges that one afresh. Nothing is
  retried on a timer and the editor never launches over the skipped daemon;
  the relay exits 0 when the editor ends it (workspace swap, shutdown).
  The editor retires an incompatible daemon only over a relay connection
  (`welcome.via = "relay"`).
  A daemon whose start time is unknown (`welcome.daemon` without
  `start_time`) cannot be named with `--skip-instance` (an instance id needs
  both, §19.5). When the editor finds such a daemon incompatible it closes
  that relay and stays in-process for the session; it spawns no skip relay,
  and retries only on `:LoomworksDaemon connect`.

**Interface client.** *(Step 5g.3: discovery through `Root.describe` with
`welcome.objects` as the fallback, the `/tasks` and `/workspace`
subscriptions, `objects_changed` and the per-feature note; the views and
operations: plan, steps 5j–5o.)* On every connect, including
each reconnect, the editor **discovers** the daemon through the root object
(`welcome.objects`, `Root.describe`; §19.20), picks per interface the highest
version both sides support, and subscribes to the views and tasks it shows,
taking their full state from each subscription's `initial`. A missing or
incompatible interface degrades only the feature that needs it, with one
Runtime-line note naming the interface and both versions (e.g. `lsp
configuration: daemon offers loomworks.LspConfig/2, editor needs /1`); it
never fails the connection or the other features. The describe is bounded
(about 3 s) and never blocks the editor; when it fails or times out the editor
uses `welcome.objects`. An interface that appears later (the root's
`objects_changed`) is subscribed to then, and a refused subscription is
retried once, on the next `objects_changed` or reconnect. A missing interface
is noted only when the editor gets nothing for it: a daemon whose
`describe` reports `delivery: "subscription"` sends a transport-11
connection only what it subscribed to, so a missing interface is noted; a
daemon of transport 11 without it (step 5g.1, or a describe that failed)
still sends the protocol-10 broadcasts, and one that offers none of the
observed views is observed through them without a note. Only a transport mismatch
(no overlap of the ranges, §19.9) makes the daemon incompatible as a whole.
Against a daemon of protocol 10 (no `welcome.objects`) the editor observes
through the v0 broadcasts as below and notes interface features as "daemon
too old".

*(Future:)* The editor's run and debug launches (§8.6) take the CLI's split
(§19.15, Run): `prepare_run` in the daemon, then the returned launch spec
handed to the editor's task runner (run) or to the debugger as the debuggee's
program, arguments, working directory and environment (debug). The program
is then the editor's, never the daemon's. Until the editor moves its
operations to commands, its launches stay in-process; the observer shows a
CLI run's preparation as a remote task (`kind = run`) like a build, and never
the program.

**Step 4: the observer.** In `daemon` mode (selected as in §19.1: the
environment, the setup option `runtime.mode`, then lw's `runtime-mode` setting), each
workspace the editor loads gets an **observer**. It watches the task streams
and model changes of operations started elsewhere (a `lw build` in a
terminal). It runs none of the editor's own operations, which stay on the
in-process path. In `in-process` mode nothing below happens.

- **Host binary.** The observer selects the host binary it launches the
  daemon from; first match wins:
  1. **Explicit**: `LOOMWORKS_LW`, then the setup option `binary.path`. Used as
     is (no hash check: the user chose it); a relative value is made absolute
     against the editor's current directory when it is selected, so the file
     checked is the file run. A value naming no file — on Windows, no `.exe`,
     the rule of step 2 — is a note and **stops the search**: the editor never
     runs another `lw` instead of the one the user named.
  2. **`lw` on the search path**: only the search path's **absolute** entries,
     in order — never the current directory, which for the editor is a
     repository it opened, possibly untrusted (§17); relative and empty
     entries are skipped (an absolute entry naming that directory still
     counts). On Windows the file looked for in each entry is `lw.exe` (a
     script shim cannot start the daemon detached), so an extensionless `lw`
     or an `lw.cmd` in an earlier entry neither is chosen nor hides a later
     `lw.exe`. Used when it offers the interfaces the plugin needs, as the
     pre-launch probe below decides *(step 5h.5, `provision/probe.lua`)*.
  3. **The plugin-managed `lw`** under the editor's data directory: used when
     there is no system `lw`, or when it is too old (a status note says so).
     "Too old" is a **definite** failure of the probe; an unknown result is
     not a failure.

  **Pre-launch probe** (step 5h.5). Before launching from an `lw` found on
  the search path or named explicitly, the observer runs `<binary> version
  --json` (§16.41) — asynchronously, bounded by a short timeout (about 3 s),
  with the editor's data directory as working directory (never the
  workspace) and no workspace-sourced environment — and checks the
  descriptor with the interface check of "Plugin pin" below (transport
  overlap, and the root and feature interfaces the editor uses), except that
  its schemas must **equal** the plugin's: a difference in either direction
  is a definite failure — an older `lw` cannot read the workspace files at
  the plugin's format, a newer one writes a format the editor will not
  observe, and the managed `lw` the search falls through to matches the
  plugin exactly. (An already running daemon is weighed separately at
  connect: newer schemas are refused, older ones are observed and weighed
  for a retirement under "Retiring an incompatible daemon" below; the pin
  check refuses only newer schemas.) The verdict is cached per process by the binary's path, size
  and modification time; the selection itself stays synchronous over cached
  verdicts, and while a probe runs the Runtime note says so; should the
  probe's own answer never arrive, the observer stops waiting shortly after
  the probe's timeout and goes on as for *unknown*. Verdicts:
  - **compatible** — the binary is used;
  - **incompatible** (a definite failure: no transport overlap, schemas
    older or newer than the plugin's, a missing root interface) — a
    search-path `lw` is skipped with
    a status note naming the problems ("too old/incompatible: …") and the
    search goes on to the managed `lw`; an explicit binary is never
    replaced (rule 1), the verdict is only noted;
  - **unknown** (no descriptor — an `lw` older than §16.41, or one with no
    system Lua — a descriptor with no `schemas`, or a timeout) — the binary
    is used and the handshake decides.

  A missing feature interface is not a failure: that feature degrades with a
  note ("Interface client" above). The managed `lw` is not probed at run
  time: the pinned release was checked when it was pinned, and a channel
  release is checked through its published descriptor before it is
  downloaded ("Channel upgrades" below).

  The setup option `binary.prefer = "managed"` (default `"system"`) puts 3
  before 2. Its consequence: the daemon's version can then depend on who
  launched it (the CLI starts the daemon from its own `lw`, the editor from
  the managed one; §19.9 decides what each does with the other's). Running a
  host binary with the plugin's or another Lua source tree (`binary.source`,
  `LOOMWORKS_LUA`, §16.11) is a development opt-in only, never automatic: it
  sets the source of the binary selected above and never selects one.

  The editor **reads no `lw.pin`**. A global or managed `lw` follows the
  repository's pin itself: the daemon commands the editor launches (`daemon
  run` and its `--stdio` relay form, step 5i) are redirect commands
  (§16.23, step 5h.2), so they run the pinned version — unless the pinned
  release predates the command (§16.23 "A pin older than the command"): then
  the launch is refused and the editor works without a daemon. Compatibility is
  decided after connecting, by the handshake and `Root.describe` (§19.9,
  §19.20); the pre-launch `lw version --json` probe (above, step 5h.5) is only
  a quick pre-check. It describes the binary probed, not what a redirect
  command runs in a pinned repository (§16.41): a repository pinned to an
  incompatible release is caught by the handshake after the launch, and the
  once-per-version rule of "Retiring an incompatible daemon" keeps the editor
  from retiring that release's daemon in a loop. Only what the plugin itself
  downloads is hash-checked (against the hash the plugin release carries,
  "Plugin pin" below, or one the pinned `lw` obtained from a release's signed
  `SHA256SUMS`, "Channel upgrades" below); binaries the user
  installed (search path, explicit) get compatibility checks only. In daemon
  mode the plugin may download its managed `lw` automatically (step 5h.3;
  `binary.download = false` turns that off): official releases only (§17.8).

  **Plugin pin** (step 5h.4). The plugin carries the release it downloads:
  `lua/loomworks/provision/pinned.lua`, `{ version, assets = { [<host asset>]
  = <sha256> } }` with one hash per published host asset (`lw-linux-x86_64`,
  `lw-macos-arm64`, `lw-windows-x86_64.exe`; the plugin keeps its own copy of
  that table). It is never edited by hand: `scripts/release/pin.sh` writes it
  from a release's `SHA256SUMS` after verifying `SHA256SUMS.sig` with the
  committed release key, and only when the release's descriptor (§16.41)
  offers what the editor client needs — a transport range overlapping the
  plugin's, schemas no newer than the plugin's, and `/` `loomworks.Root/1`,
  `/tasks` `loomworks.Tasks/1`, `/workspace` `loomworks.Workspace/1` (one
  check, `provision/needs.lua`). The pin is not part of the lw bundle, so the
  pin commit changes no release asset. Releases are cut in two stages: the
  build stage builds every asset of `vX` from a build commit C into an
  unpublished draft release (no tag, C recorded as its target); the cutter
  pins the draft, commits only `pinned.lua` on top of C and tags that commit
  `vX`; the tag push never rebuilds — it publishes the draft (the one draft
  named `vX`; none or several fail) only when the
  tagged commit changes nothing but `pinned.lua` since C, the pin names `X`
  and equals the draft's signed hash for every host asset, the signature
  verifies, every host binary of the draft is present and matches
  `SHA256SUMS`, and the
  descriptor passes the interface check. Any failure, or no draft, publishes
  nothing. The cutter pushes only the tag first and pushes the pin commit to
  a branch only after the publish succeeded, so a failed gate leaves no
  branch pinning an unpublished draft. Hence a plugin checkout always pins a
  published release, never one newer than every release. Ordinary CI runs the same check on the pinned
  release as a warning only: a development checkout may need interfaces newer
  than the last release (the editor then degrades with feature notes;
  developers point `binary.path` / `LOOMWORKS_LW` at a newer `lw`).

  **The plugin-managed `lw`** (step 5h.3) lives at
  `<editor data>/loomworks/lw/<sha256>/lw` (`lw.exe` on Windows),
  content-addressed by the binary's SHA-256, so a binary is never replaced in
  place (a running daemon keeps its file). The binary the plugin wants is a
  release version, a host asset name and that asset's SHA-256: this host's
  asset of the plugin pin ("Plugin pin" above; a platform with no published
  asset, or a pin without this host's asset, wants none and the slot only says
  why), or — with `binary.channel` set — a newer compatible release of that
  channel ("Channel upgrades" below; step 5h.5). When the selection reaches a wanted managed `lw` that is not
  installed, that decides the search: in daemon mode the observer downloads it
  — asynchronously, the editor stays in-process meanwhile and the Runtime note
  says it is downloading, from where — then launches from it (or connects to a
  daemon that appeared meanwhile). The editor's data directory and
  `loomworks/` under it may be links (followed); `loomworks/lw/` and the slots
  are created as, and must be, real directories. The download goes into a
  temporary file `<sha256>.<pid>.<n>.dl` next to the slots (unique per
  process and attempt); whatever is at that path first (a stale file, a link)
  is unlinked, never written through. Its SHA-256 must equal the wanted one,
  then it is made executable (POSIX) and renamed into its slot (on Windows
  the rename is retried briefly while the new file is held, e.g. by an
  antivirus scan). A failure (network, missing asset, hash mismatch) removes
  the temporary file, installs nothing and is one note naming the binary and
  why (running in-process); it is not retried until `:LoomworksDaemon
  connect`. Requests for one hash share one download; a slot another editor
  filled meanwhile is kept. `:LoomworksDaemon connect` while a download runs
  aborts it (curl is stopped, the temporary file removed) and starts over;
  unloading the workspace aborts it. A transfer is bounded: a connection
  must come up within 20 s, one slower than 1 KiB/s for 30 s is dropped, none
  runs past 300 s (three attempts, lw's retry rule).
  A managed binary is present only as a regular file (lstat: a link in a slot
  is never launched) whose SHA-256 matches its slot's name; the editor hashes
  it once per process before first using it. One that does not match is
  corrupt: never launched, one note, and in daemon mode downloaded again and
  renamed over it. The source is `<base>/<asset>` for a release-source override (the
  setup option `binary.release_url`, else `LOOMWORKS_RELEASE_URL`: a local
  directory, `file://` or a flat mirror, as for `lw`, §16.29), else `lw`'s
  fixed origin's `releases/download/v<version>/<asset>`; http(s) goes through
  `curl` from the search path's absolute entries; from an https source a
  redirect may lead only to https (`--proto-redir =https`; a configured http
  mirror is used as given). The hash, not the transport, is the trust anchor. `binary.download = false` turns downloads off (the
  managed source is then absent, with why); `:checkhealth` never downloads,
  it reports what would be downloaded and the state of a download.
  Each slot's directory mtime is its last use: set when the slot is created
  or installed into, and whenever an editor selects the binary (marked at
  most once an hour) or connects to a daemon whose handle names it.
  After a successful download the observer prunes the other slots (only when
  no download runs, never without a wanted hash; the wanted hashes are the
  pin's and, with `binary.channel` set, the accepted channel release's —
  both are kept, "Channel upgrades" below): only entries named exactly
  64 lowercase hex digits that are real directories (a link or junction is
  skipped, never followed) whose realpath is a direct child of the realpath of
  `<editor data>/loomworks/lw`, itself a real directory, and that hold only the
  regular file `lw`/`lw.exe`; never the binary of a daemon the editor launched
  or observes, or the live daemon's, and never a slot used within the last 14
  days. The last rule protects what one editor cannot see — another editor's
  daemon (another workspace, another plugin version with another pin) and an
  install in progress — since POSIX lets a running binary be unlinked; a
  daemon left running more than 14 days with no editor connecting may lose
  its file (it keeps running; a later launch downloads it again). The file is
  unlinked, then the empty directory removed (a failure — on Windows a
  running binary — skips it). A temporary file another process left is
  removed once a day old. A search-path or explicit `lw` is probed before
  the launch ("Pre-launch probe" above, step 5h.5); the managed `lw` is not.

  **Channel upgrades** (step 5h.5; *implemented*,
  `provision/channel.lua`). The setup option `binary.channel`
  (`"stable"` or `"unstable"`; default unset = the plugin pin only, no
  channel lookups) lets the managed `lw` move ahead of the pin. It applies
  only when the selection reaches the managed source, `binary.download` is
  not `false`, `binary.source` is not set (a development binary is never
  channel-resolved) and the runtime mode is daemon. In the background, at most
  once a day and on `:LoomworksDaemon connect`:
  1. The **pinned** managed `lw` is made present and verified first (the
     download above). Only that binary resolves a channel — never an `lw`
     from the search path or an explicit one, which are the user's to update.
  2. It runs `<pinned lw> release query --channel <channel> --json` (§16.42)
     with the release-source override (`binary.release_url`) and the
     install-folder override of "Install location" passed through, the
     editor's data directory as working directory, and bounded fetch limits.
     The output must name a valid release version, this host's asset and a
     64-hex hash, and carry the release's descriptor; that descriptor must
     pass the interface check of "Plugin pin", with the pre-launch probe's
     schema rule (schemas **equal** to the plugin's: the managed `lw` is what
     the search falls through to, and a daemon with older schemas would be
     weighed for a retirement).
  3. A result that passes and names a version newer than the current wanted
     one (§16.29 ordering: a pre-release ranks below its release) is
     **accepted**: it becomes the wanted binary and is downloaded as above,
     hash-checked against the hash from the query. It is recorded as accepted
     only once that download succeeded; a failed download is one note and
     the current wanted binary stays. A running daemon is not
     switched — a compatible daemon is never retired for being older; the
     next launch uses the new binary, and the Runtime note says so.
  4. A result that fails the check is one note ("<channel> offers lw <v>,
     which this plugin cannot use (…); staying on <v'>") and is recorded so
     the same release is not checked again.

  The wanted binary is the newer of the pin and the last accepted channel
  result, so it never goes below the pin. The last result is kept in the
  plugin's own file `<editor data>/loomworks/channel.json` (outside
  `loomworks/lw/`, written atomically, never pruned); changing
  `binary.channel` invalidates it. Switching from `unstable` to `stable`
  keeps a newer accepted pre-release until stable overtakes it (as for lw's
  own bundles, §16.29); unsetting `binary.channel` returns to the pin. A
  query result older than the accepted one (a withdrawn release) is ignored.
  Offline, a bad signature, a tampered descriptor or a pinned `lw` older than
  the query command are one note each; the editor keeps the current wanted
  binary, downloads nothing and retries only at the next interval or an
  explicit connect. A release-source override supersedes the channel; the
  query reports that and the editor notes it (§16.29: never silent).
  `:checkhealth loomworks` reports the last check and never queries. When a
  search-path `lw` is selected, `binary.channel` has no effect and the status
  note says why (`binary.prefer = "managed"` changes that).

  **Retiring an incompatible daemon** (step 5h.5; §19.9 "Editor
  retirement"). On connect, a daemon is **incompatible** with the editor
  when its transport range does not overlap the editor's (detected at the
  handshake; `ping`, `status` and `retire` are version-stable, §19.8, so the
  editor can still authenticate and retire it), when it does not offer
  `loomworks.Root/1`, or when its schemas are older than the editor's (it
  cannot read the editor's files). The `loomworks.Root/1` requirement applies
  only to a transport (protocol) 11 connection whose welcome lists the
  daemon's interfaces (`welcome.objects`); a protocol-10 daemon offers no
  interfaces and is judged by its version and schemas only. A missing
  feature interface only degrades that feature ("Interface client") and is
  never a reason to retire. The
  editor sends `retire` (never `stop`) only when all of these hold:
  - the daemon is idle (no busy client, §19.9 "Busy");
  - its schemas are not newer than the editor's;
  - the binary the editor selected passed the interface check (the probe's
    *compatible* verdict, or the managed `lw`);
  - that binary's `lw_version` differs from the daemon's;
  - the editor has not already retired a daemon of that `lw_version` for
    this workspace in this editor session.

  Then the "Retiring" path below relaunches once. A busy incompatible daemon
  is a note ("incompatible daemon is busy; retiring when idle") and is
  re-checked through `status` about every 30 s. When the once-per-version
  rule stops a retirement — the successor runs the same version again,
  typically because a repository pin redirects to it — the note says so
  (the daemon runs lw <v> again, likely a repository pin; update the pin or
  the plugin); when that earlier retirement failed (below), the note says
  instead that retiring a daemon of that version failed earlier this
  session, and it is not tried again. A compatible daemon is never retired by the editor, whatever
  its version.

  A daemon whose only incompatibility is older schemas (transports overlap,
  root interface present) is observed as usual ("Connect" below) while the
  editor weighs it — while the selected binary is probed, while the daemon
  is busy — and for the rest of the session when the editor declines to
  retire it; the Runtime line says why. Any other incompatible daemon is not
  observed: the editor holds its connection only to ask `status` and send
  `retire`, ignores anything else it sends, and closes it when it declines.
  While a `status` is unanswered no other is sent; a `status` still
  unanswered at the next re-check ends the wait: the daemon is neither
  retired nor relaunched, the Runtime line says it stopped answering, a held
  connection is closed and an observed daemon stays observed (its keepalive
  notices one that is gone). `retire` is sent at most once. An error reply
  to `retire`, or none within one re-check interval, is a failure: the
  Runtime line says so, nothing is relaunched, an observed daemon stays
  observed, and the once-per-version rule still counts the attempt (as a
  failed one). The connection closing
  instead of a reply counts as retired. Tasks of an observed daemon end when
  its connection closes, as for any drop. While the editor asks a daemon
  that reports no `busy_clients` (§19.9 "Busy"), its own observer connection
  is counted among the observers, not subtracted again.

  **Install location.** Everything the plugin installs (host binaries,
  release bundles, and what an `lw` the plugin runs downloads for it: its
  own provisioning and the pin redirect's, through that `lw`'s install-folder
  override `LOOMWORKS_INSTALL_DIR`, §16.22, step 5h.2) stays under the
  editor's data directory (`<editor data>/loomworks/`) — except the bundle
  copy a pinned release older than the install folder provisions for itself,
  which lands in `lw`'s per-user data directory (§16.22). The plugin never installs a system-wide `lw`
  and never writes configuration into the user's home. Shared runtime state
  stays where `lw` keeps it, for every `lw` on the machine: daemon sockets and
  identity, the trust store (§17.2), daemon logs. The plugin reads `lw`'s
  per-user configuration (its settings, §19.1) and writes it only on an
  explicit user action.

  With none, the status page shows one inline note naming each source and
  why it gave nothing (no host binary: running in-process); while the
  observer launches, its note names the binary and its source.
  `:LoomworksDaemon status` and `:checkhealth loomworks` list every source
  with its verdict. The editor never launches a daemon from its own plugin
  source unless `binary.source` asks for it, and runs no loopback runtime
  until the thin-client part of §19.19 step 5 (the CLI's attached runs of
  step 5e do not include the editor). Until step 5i PR G1 it still watches
  for a daemon another client starts and observes that one. From PR G1 it
  does not: the editor follows daemons only through relays, which need a
  host binary, so with none it spawns no relay, stays in-process, and does
  not observe a daemon another client started ("End state").
- **Launch.** The observer launches `<binary> daemon run --root <root>`
  (§19.10: detached, no inherited handles, the state directory as working
  directory) only when no daemon is live on workspace load or on an explicit
  `:LoomworksDaemon connect`, and once after a retirement (below). Readiness is not awaited in a blocking wait: the
  observer watches the handle. An early exit other than "another daemon won"
  is a note. A daemon that is starting, hung, of another host, or attached is
  not launched over; the observer notes it and watches. *(Until step 5i PR
  G1. From G1 the editor launches nothing itself and starts no child daemon:
  an ordinary relay launches the daemon when none is live, on the same
  occasions ("Through the relay" above, its forms), and a relay's exit before
  `welcome` replaces the early-exit note ("Exit before `welcome`").)*
- **Connect.** The observer handshakes as `client = "editor"`,
  `role = "observer"`. It observes a daemon whose transport range overlaps
  its own and whose schemas are not newer (§19.9; the host version may
  differ; editors of protocol 10 required an equal protocol). *(From step 5i
  PR G1 the handshake runs inside the relay and the editor judges
  `welcome.daemon`; a `welcome` without `via` is observed without this check,
  "Through the relay" above.)*
  - **Incompatible daemon.** A daemon with older schemas (and nothing else
    wrong) is observed; any other incompatible daemon (no transport overlap,
    newer schemas, or, over transport 11, a missing root interface) the
    observer notes and does not observe, and does not connect to it again
    (from step 5i PR G2, through the relay it follows a successor with
    `--no-launch --skip-instance`, "Skipping an incompatible daemon" above).
    It never restarts an incompatible daemon; it retires it only under
    "Retiring an incompatible daemon" above *(step 5h.5)*, which also says
    how long an older-schema daemon stays observed.
  - **Keepalive.** While connected it sends `ping` about every 30 s.
- **No relaunch after a stop.** When the connection drops because the daemon
  stopped (`lw daemon stop`), crashed or dropped this observer, the observer
  never launches a daemon by itself. This keeps `lw daemon stop` meaningful.
  It watches the handle (about every 2 s) and connects again when a live
  daemon appears. It skips one it was told is `retiring` or found
  incompatible, identified by pid and start time. *(Until step 5i PR G1;
  then replaced by "Following a stopped or retiring daemon without
  relaunching it" and, from PR G2, "Skipping an incompatible daemon" under
  "Through the relay" above — a `--no-launch` relay, with `--skip-instance`
  for an incompatible daemon, instead of watching the handle. The editor
  then keeps no list of skipped daemons of its own.)*
- **Retiring.** On `retiring` (broadcast, or in `welcome`) the observer
  disconnects at once, so a version change completes (§19.11). Once that
  daemon has exited and no other daemon is live, the observer launches one
  daemon itself (one attempt, not a loop: an early exit is a note) and
  connects to it; a successor another client started first is observed
  instead. *(Until step 5i PR G1; then replaced by "Following a stopped or
  retiring daemon without relaunching it" under "Through the relay" above —
  the wait happens in a relay (`RELAY_RETIRE_WAIT`, or `--no-launch`, with
  `--retiring` when the instance is known, ending in exit 16), and the one
  launch per retirement episode is an ordinary relay's.)*
- **Model changes.** On `model_change` the editor applies its files' pending
  changes at once (§19.12).
- **Tasks.** Each observed task becomes a **remote task** in the editor.
  - **Resolving.** Its `start` meta is resolved at the boundary. The profile
    key is looked up among the workspace's profiles. Each unit is matched to
    that profile's project-in-profile with the same project key and
    configuration-unit key, and through it to its configuration unit. A key
    that does not resolve (another working copy, a profile the editor has not
    loaded yet) is kept and shown **by name only**; no domain object is
    created or hydrated for it.
  - **Running state.** A remote task puts the same runtime state on the
    editor's objects as a local operation of its `kind` would (§3): each
    resolved configuration unit reports `building` (or the kind's state), so
    its build directory shows it too, and the resolved profile counts as
    having an active operation (spec/ui.md §1.5). A remote `clean` shows its
    units `cleaning`, the display of the transient clean state (§3.1, transition rule 5),
    without changing their cached state; a remote `test` or `run` shows
    `building`. *(Step 5d.)* A remote `reset` shows its units
    `deleting`, the display of the transient deletion state (§3.1, transition
    rule 5) of the in-process reset, whose deletion is not a clean. A
    `reset --all` has no profile (`meta.scope = "all"`, §19.15 Reset): its
    units are resolved by project key and configuration-unit key among the
    workspace's configuration units, and every profile with a resolved unit
    counts as having an active operation. The state is runtime-only:
    the editor never writes the cache or the working copy for a remote task
    and runs nothing. It never blocks an editor operation: the cross-process
    build-directory locks (§16.6) do.
  - **Joining late.** On each connect the observer sends `status` and adopts
    every task in its `tasks` (§19.11) as a remote task, its output starting
    from that moment; a task already ended is never shown.
  - **Output.** The task's lines and output are kept, capped at about 1 MiB
    per task, then one truncation notice.
  - **End.** A task ends on `done` (success, failure or cancellation), or
    when the connection drops (it is then shown as ended "the workspace
    daemon disconnected"). Either way its runtime state is cleared at once;
    the unit's state after the task is whatever the editor's files then say.
    The daemon sends the `model_change` of the task's cache write-back
    (§19.12) before its `done`, so the editor has already reloaded the
    outcome when the running state clears.
  - **UI.** A remote task is shown exactly as a local task of the same kind
    and profile: in progress (fidget, the same entry and end message — for
    a `clean`, `cleaned` / `clean failed`, as a local clean's; for a
    `reset`, which has no local editor task, `Resetting` and `reset` /
    `reset failed`, with the profile's name or `--all`), in the
    status page's Profiles and Tasks sections (spec/ui.md §1.5, §1.9), and
    in the status line. It is neither cancelled nor restarted from the editor
    (§19.15). Its only difference is an **origin marker** naming who started
    it, from `meta.origin` (§19.15). It is not added to the task runner's task
    list; that, and turning its output into the quickfix list and diagnostics,
    belong to the step where editor operations themselves run in the daemon.
- **Teardown.** Unloading or swapping the workspace stops its observer: the
  timers stop, the connection closes, remote tasks are cleared. The daemon
  keeps running (§19.11). *(From step 5i PR G1 the connection closes by
  closing the relay's standard input, a waiting relay is ended the same way,
  never by a process-tree kill: "The relay process" under "Through the
  relay" above.)*
- **Quiet degradation.** Every problem is the observer's one current note,
  shown on the status page's Runtime line, never a notification or a repeated
  message.

A version mismatch the editor cannot repair by restarting (its plugin code and
the resolved binary differ in protocol or schemas) is shown inline. The editor
keeps running in-process. The note is never silent: it stays on the Runtime
line (warning highlight) for as long as the mismatch lasts, naming both sides'
protocol (or schema) and versions, the binary's path when known (the
daemon's handle `exe`, §19.6, whoever started it; an older daemon's handle may
not name one), and the remedy (update
the plugin, or pin or install a matching lw), e.g. `Runtime:   daemon (lw
setting) — lw v0.1.44 (protocol 7) does not match this plugin (protocol 6):
update the plugin or the pin — running in-process`. *(Step 5g.3.)*
From protocol 11 this whole-daemon note applies only to a transport mismatch;
a missing interface version is the per-feature note of "Interface client".

### 19.17 Parity

*Status: master for `lw build` (`tests/daemon_build_cli_spec.lua`: every
build form both ways — the same output, exit code and persisted cache;
`tests/daemon_build_service_spec.lua`, `tests/daemon_real_build_spec.lua`)
and the batch `lw test` (`tests/daemon_test_cli_spec.lua`: passing, failing,
runner arguments, JUnit (also a runner that wrote none), a failed build, an
unknown or missing profile, both ways — the same output, exit code, JUnit
files and persisted cache) and `lw run`
(`tests/daemon_run_cli_spec.lua`: the default target, a named build target
and command configuration, the two-operand form, forwarded arguments,
`--cwd`, `--prefix`, `--print[=json]`, `--dry-run`, `--no-build`, a failed
build, a failed deploy, an unknown, ambiguous or unset target, the program's
exit status, both ways — the same output, exit code, deploy records and
persisted cache; plus: the program runs after the task ended and every lock
was released (a `lw build` of the profile proceeds while it runs), it
survives `lw daemon stop`, two runs at once, the not-carried device forms
print their line) and `lw clean` (`tests/daemon_clean_cli_spec.lua`: a module
clean, a core-performed wipe, a refused unsafe path, nothing to clean, a
failing step, an unknown or missing profile, both ways — the same output, exit
code, build-directory contents and persisted cache; plus cancellation during a
step and during a wipe; `tests/daemon_clean_service_spec.lua`: the daemon
answers `ping` while a wipe runs, a cancelled wipe stops between entries and
holds its locks until it has); `lw reset`
(`tests/daemon_reset_cli_spec.lua`: a profile reset, `--all` with an
orphaned directory, a directory shared with another profile kept, nothing to
reset, `-y`, a confirmed and a declined prompt, a non-interactive refusal
without `-y`, an unknown or missing profile, both ways — the same output,
exit code, build-directory contents and persisted cache; plus a plan changed
between listing and confirmation, a second request that cannot be routed
(the daemon stopped while the user answered) and cancellation during the
removal; `tests/daemon_reset_service_spec.lua`: the daemon answers `ping`
while a reset removes, `confirm` takes no lock and changes nothing, a changed
plan is refused, a held build-directory lock refuses the reset naming the
holder, a cancelled reset stops between entries, leaves the cache `unknown`
and holds its locks until it has, `--all` is one task without a profile and
an observer shows every profile with one of its units `deleting`; a directory
that cannot be removed is `tests/cli_reset_spec.lua`'s, the deletion and its
check being the one path both hosts run); the projection half #88.*

Because both paths share the deserializer and serializers, correctness is
differential: running an operation in-process and through the daemon MUST
leave byte-identical workspace files, and the client projection MUST serialize
identically to the daemon's model. Every operation moved in §19.19 carries such
a test before its routing is enabled.

### 19.18 Device and log records

*Status: #88 (schema scaffold); wiring future.*

Device logs travel on the task-stream channel as normalized records
`{ ts, level, tag, pid, message, fields? }` (unknown level → a default,
unknown keys → `fields`). Moving a platform module's device logic into the
runtime is deferred until that module is actively developed.

### 19.19 Transition order

*Status: plan. Each step is shippable on its own and keeps master green.*

1. **Operation locks** — §19.3, §19.4 and §19.5 on the in-process path: the
   workspace operation lock, the lock order, `lw nuke` taking build locks,
   journalled multi-file commits, dead/hung holder recovery and
   `--break-locks`. No daemon involvement.
2. **Lifetime** — §19.2, §19.6–§19.11 behind `runtime-mode daemon`: the
   daemon starts and stays running, answering `ping`/`status` only; `lw daemon
   status|stop|restart|kill`; the runtime log; the Runtime row.
3. **First operation** — `lw build` routed to the daemon (§19.15). *(Done.)*
4. **Editor connects** — observer + keepalive (§19.16). *(Done.)*
5. **Remaining operations**, one at a time, each with a parity test (§19.17);
   then the loopback transport, so attached runs use the same code; then the
   CLI and the editor stop loading the workspace themselves. Routed so far:
   the batch `lw test`; the preparation of `lw run` (§19.15, Run; protocol
   6) — the program runs in the client; device runs and the editor's
   launches stay in-process.
   - **5c — `lw clean`** (§19.15, Clean; protocol 8): executed in the daemon
     under exclusive build-directory locks, with the in-process deletion
     safety for a core-performed wipe. Configuring is already routed as a
     step of `lw build`. `lw nuke` and `lw device clean` stay
     in-process (§19.15, Not routed). *(Done.)*
   - **5d — `lw reset`** (§19.15, Reset; protocol 9): executed in the daemon
     under the workspace operation lock and exclusive build-directory locks,
     through the same deletion as in-process; its confirmation asked by the
     client from the daemon's listing, the answer carrying a token of the
     listed plan.
   - **5e — Loopback for the routed operations** (§19.1 "Loopback during the
     transition"): in `daemon` mode an attached selection runs `lw build`,
     `lw test`, the preparation of `lw run`, `lw clean` and `lw reset` through
     the daemon's own server and service in the client process, over the
     loopback transport, holding the runtime lock in `attached` mode; the
     `in-process` default is unchanged. The transport and the attached
     server are in place, and the CLI uses them (done). Profile and
     project mutations, publish / import / pull and devices are routed —
     shared and attached — later, with the command machinery of §19.14. The
     editor gets no loopback runtime (D8 is superseded) and no private
     daemon: when the shared daemon cannot be started it runs degraded
     (steps 5i, 6b).
   - **5f — Plugin/binary boundary**: the classification manifest and the
     ratcheting guard test (`tests/split`), no behaviour change. *(In review,
     #149.)*
   - **5g.1 — Transport 11 and the root object** *(done)* (§19.8, §19.20): the envelope
     (`call`, structured `error`, `signal`), `loomworks.Root/1`
     (`describe`, `schema`, `subscribe`, `unsubscribe`, `objects_changed`),
     `welcome.objects`, `protocol_min`; the daemon accepts protocols 10 and
     11; one dispatch table, through which the protocol-10 kinds are served as
     v0 aliases (no behaviour change); the schema directory with the
     meta-schema, the transport, `loomworks.Root/1` and `loomworks.Common/1`
     documents; the schema validator; the lint and additive-ratchet tests.
   - **5g.2 — Existing operations as interfaces** *(done)*: `loomworks.Build/1`,
     `Tests/1.run`, `Launch/1.prepare_run`, `Toolchains/1.list`,
     `Profiles/1.compiler_cache`, `Workspace/1` (`header`, `changed`),
     `Tasks/1` (`list`, `cancel`, the subscription) and
     `lw.internal.Snapshot/1`. The CLI switches to calls in the same step (it
     is the same artefact); the v0 kinds keep serving older editors. The
     conformance runner over the standard-I/O transport, with transcripts for
     each. *(Done. Part A: `Workspace/1` (`header`, `changed`),
     `Tasks/1` (`list`, `cancel`, the subscription),
     `lw.internal.Snapshot/1`, `lw daemon run --stdio`, the conformance runner
     and the transcripts of these and `Root/1`. Part B: `Build/1`,
     `Tests/1.run`, `Launch/1.prepare_run`, `Toolchains/1.list`,
     `Profiles/1.compiler_cache`, `Workspace/1.header_changed`, opaque string
     ids and the CLI's switch to calls (`daemon/calls.lua`).)*
   - **5g.3 — Policies** *(done)*: `lw_version` equality as the CLI's policy through
     `describe` (§19.9); busy = owns a task or a command in flight (§19.9); the
     editor's observer re-describes on connect and subscribes to `/tasks` and
     `/workspace` when the daemon offers them (later too, on
     `objects_changed`), otherwise uses the v0 broadcasts; the guard's
     interface ratchet (every plugin-side call names an interface version that
     has a schema and client-conformance transcripts; a site naming an
     interface at run time is an allow-listed exception). *(Done:
     `ensure.policy`, `Server:conn_busy` / `status.busy_clients`,
     `observer._subscribe`, transport-11 delivery by subscription, the guard's
     interface ratchet in `tests/split`. Deferred to 5j: checking that the
     methods and signals the plugin uses on an interface version are covered
     by its transcripts.)*
   - **5h — Editor-side binary selection and provisioning** (§19.16 "Host
     binary"), used first only for the observer's binary:
     - **5h.1** — the selection order (explicit, `lw` on the search path, the
       plugin-managed `lw`, `binary.prefer`), the install-location rule, the
       status page and `:checkhealth` listing; `daemon/host_binary.lua` and
       its reads of `lw.pin` and of lw's pinned cache are removed. No
       downloads. *(Done.)*
     - **5h.2** — binary side: `lw version --json` (also a release asset
       listed in `SHA256SUMS`), the daemon commands as pin-redirect commands
       (§16.23), the install-folder override for an `lw` the plugin runs.
       *(Done.)*
     - **5h.3** — download, verify (against the plugin's hash) and cache the
       managed `lw` under the editor's data directory; `binary.download`,
       `binary.release_url`; pruning of other managed binaries. *(Done.)*
     - **5h.4** — the plugin's own pin (a hash per host asset, outside the
       bundle), the release sequencing that commits it, the CI interface
       check. *(Done: §19.16 "Plugin pin"; first seeded with
       0.1.43-beta.15, which predates the descriptor.)*
     - **5h.5** — channel upgrades through the verified `lw`
       (`binary.channel`, `lw release query`, §16.42; §19.16 "Channel
       upgrades"), compatibility-driven selection (§19.16 "Pre-launch
       probe"), the editor's retirement of an incompatible idle daemon
       (§19.16 "Retiring an incompatible daemon"). In parts: the spec; the
       binary's `release query` *(done)*; the probe in the selection
       *(done)*; the retirement *(done)*;
       `binary.channel` *(done)*.
   - **5i — Connections** (§19.10 "Connections", §19.11, §19.15 "Task
     ownership", §19.16 End state): `lw daemon run --root <root> --stdio`
     becomes a connect-or-start relay — discovery, launch, authentication and
     the handshake for the editor, which then reads none of lw's internal
     files; it forwards frames opaquely, so it never changes for a new
     interface (this replaces the separate `lw daemon attach --stdio` bridge
     planned earlier). Every CLI command that already uses the daemon
     connects or starts likewise (no new command is routed; the `in-process`
     default is unchanged). The relay's handshake (§19.8 "Relay handshake":
     the client's `hello` read first, `server_proof` verified before
     forwarding, `welcome.daemon` and `welcome.via` added), its bounded
     buffering (`RELAY_HIGH_WATER`), its wait on a retiring daemon
     (`RELAY_RETIRE_WAIT`), its `--no-launch` form that only waits for a
     daemon (the editor's after a stop or a busy retirement; with
     `--skip-instance`, after an incompatible daemon) and its exit
     statuses (§19.10 "Relay exit status"). Relays register nothing; `lw daemon list` and
     `kill --all --strays` show them as connections of their daemon, while a
     `--stdio` process the runtime lock names is still a runtime (older
     pins). Each task is owned by the connection that
     started it and cancelled when that connection closes; the CLI's two-stage
     Ctrl-C; the process-tree kill on Windows. The idle rule becomes "no
     connections and no background work", background work bounded by
     `BACKGROUND_MAX_DURATION` (10 minutes). The conformance runner gets its
     isolated daemon per case through the hidden `--private` flag, gated by
     `LOOMWORKS_TEST_PRIVATE_STDIO=1`, or a temporary root. A relay the
     editor starts applies the **editor's** compatibility rule (§19.9
     "Editor retirement", §19.16 "Retiring an incompatible daemon"), not the
     CLI's `lw_version` equality, so it never restarts a compatible daemon;
     the editor's retirement then goes through the relay connection.
     In parts: the spec *(done)*; B — connection code extracted from the
     CLI into `daemon/connect.lua`; C — the relay and `--private`; D —
     `lw daemon list` / `kill` classification of relays; E — the idle rule
     *(done: tool detection past the cap is abandoned by unloading the
     model, a run past it stops the daemon through the stop path)*;
     F — the CLI's two-stage Ctrl-C *(done)*; G — the editor uses the relay
     (§19.16 "Through the relay"): G0 its spec *(done)*, G1 the relay
     transport and lifecycle with the relay's `--retiring` flag (§19.10 "A
     named retiring daemon") *(done)*, G2 the incompatible-daemon policy over the
     relay *(done)*.
   - **5r — Warm restarts** (§19.11 "Warm restarts", §16.43), right after 5i
     (ids are not in order), in parts: A — the spec *(done once merged)*;
     B — the idle grace (`IDLE_GRACE_SECONDS` = 45 s as the default of
     `daemon-idle-timeout`, the setting still overriding it) *(done once
     merged)*; C — the
     fingerprinted per-module-type tool cache in `tools.json` (fingerprint
     includes the `lw` identity with its `lw_version`, so results of a retired
     daemon of another version are not reused; each type written atomically
     on completion, an interrupted type not written; reused on the next start
     when its fingerprint matches; the same check in the in-process CLI)
     *(done once merged)*;
     D *(optional)* — `lw daemon status` shows the idle deadline (`status`
     `idle_timeout` / `idle_deadline`) *(done once merged)*.
   - **5j–5o — Editor consumers move to interfaces**, each step landing its
     interfaces with their schemas and transcripts: `view.Header/1` and
     `view.ProjectsIndex/1` (5j); the editor's operations as calls,
     `Launch/1.prepare_debug`, `DebugConfig/1`, the editor's task runner
     tasks on `Tasks/1` (5k); `LspConfig/1` (5l); `Tests/1.discover` and
     `view.Tests/1` (5m); `view.Workspace/1` and `Devices/1` (5n); the
     command methods of `Workspace`, `Profiles`, `Projects`, `ConfigSets`,
     `Sdks` and `Maintenance` (5o).
   - ~~**5p — Editor-owned child daemon**~~ — dropped: the editor connects
     through the `--stdio` relay of 5i instead. The editor no longer loading
     the workspace itself in daemon mode is reached once 5j–5o have moved
     every consumer.
   - **5q — Module interfaces** (§19.20): `M.interfaces` registration, the
     `/modules/<id>` objects, a first module interface with its schemas and
     transcripts in the module's repository. Any time after 5g.2.
   - **Retirement of protocol 10**: `protocol_min` is raised to 11 and the v0
     aliases are deleted once no client in this repository sends a v0 kind
     and the deprecation window (§19.20) has passed since the first stable
     release containing 5g.3.
6. **Default flips** to the binary path for the CLI and the editor (the shared
   daemon; degraded when it cannot be started), after the criteria in DAEMON.md; the
   in-process editor stays one beta cycle behind `runtime.mode =
   "in-process"`, with a deprecation note.
   - **6b** — the in-process editor is removed; with no host binary the editor
     runs degraded.
   - **6c** — the binary's Lua moves to its own tree (mechanical); the
     protocol schemas and transcripts become the cross-repository contract,
     in a separate protocol repository pinned by both sides (§19.20).

**Later steps, in this order** (after the steps above; DAEMON.md 8a–8c):

- **8a — Workspace data to `.lw/`**: lw's workspace data files move from
  `.nvim/` to `.lw/` with a one-time migration recorded by a marker; when
  both exist and disagree, lw refuses rather than choosing. Every deletion
  scope that names `.nvim/` (the workspace-files scope of nuke, housekeeping's
  `<root>/.nvim/tmp`, the launcher cache `.nvim/cache`) is moved and
  re-reviewed for deletion safety; `lw bootstrap` writes the new ignore lines
  and the launcher templates get a new generation.
- **8b — Release v0.2.0**: `staging/daemon` is merged to master and released
  once the daemon steps and 8a are done.
- **8c — Repository split**: this repository keeps only the editor plugin;
  the CLI, the daemon, the bootstrap and protocol code, the protocol
  specification, the release workflow and the launcher scripts move to a new
  repository with their history. Existing pins and launchers download from
  the fixed release origin (§16.22), so releases stay or are mirrored there
  for a transition period; the plugin's own pin points at the new origin.

### 19.20 Interfaces

*Status: step 5g.1 is implemented on `staging/daemon`: the transport
envelope (`call`, `ok`, the structured `error`, `signal`; task frames as
before), the root object with `loomworks.Root/1` (`describe`, `schema`,
`subscribe`, `unsubscribe`, `objects_changed`, `retiring`) and
`welcome.objects` (`daemon/interfaces.lua`), the schema format and the
documents of the transport, `loomworks.Root/1` and `loomworks.Common/1`
(`spec/protocol/`, shipped in the bundle as `loomworks/protocol/`), the
validator and the lint and ratchet tests (`proto/schema.lua`,
`proto/schema_check.lua`). Arguments are always validated; results are
validated in development builds and tests (a violation is an `internal`
error), signals only logged. `forbidden` is returned by `Tasks/1.cancel`;
`not_loaded`, `stopping` and `retiring` are defined but not yet returned,
and `frozen/` is empty until a stable release ships an interface
version. Step 5g.2 part A is implemented: `loomworks.Workspace/1`
(`header`, `changed`), `loomworks.Tasks/1` (`list`, `cancel`, `started`,
`ended`) and `lw.internal.Snapshot/1` (`daemon/core_interfaces.lua`), the
standard-I/O transport (`lw daemon run --stdio`, `daemon/stdio.lua`), the
conformance engine and runner (`proto/conformance.lua`,
`scripts/conformance.lua`) and the golden transcripts
(`spec/protocol/transcripts/`, `meta/transcript.schema.json`). Step 5g.2
part B is implemented: `loomworks.Build/1` (`build`, `clean`, `reset`),
`loomworks.Tests/1.run`, `loomworks.Launch/1.prepare_run` (task-streamed),
`loomworks.Toolchains/1.list`, `loomworks.Profiles/1.compiler_cache`,
`loomworks.Workspace/1.header_changed`, references by `{ id }` or `{ key }`
and the CLI's calls over transport 11 (`daemon/calls.lua`); each of these
interfaces serves only the methods the catalogue's 5g.2 entries name, the rest
being added with their steps. Step 5g.3 is implemented: the CLI policy, the
busy rule, delivery to a transport-11 connection by subscription only and
the guard's interface ratchet. The rest is
plan: the editor's interfaces steps 5j–5o; module
interfaces step 5q; out-of-process providers are reserved and built later
(§19.19).*

**Layers.** The protocol has three layers:

1. **Transport** — framing, authentication, the handshake, the message
   envelope, flow control and the root object. Only this layer carries the
   `protocol` number (§19.8).
2. **Interfaces** — named, individually versioned contracts, each a set of
   methods, signals and errors described by a schema. One daemon may serve
   several versions of an interface at once.
3. **Data** — entities (profiles, projects, configurations, configuration
   units, launches, tasks, devices, build directories) travel as plain records
   carrying their opaque `id` (§19.12) and their `key` / `label`. There are no
   remote object references: the only per-connection state in the daemon is
   the connection's subscriptions and the tasks it owns, both dropped when it
   closes.

**Naming.**

- An interface is `<namespace>.<Name>` with a positive integer version,
  written `loomworks.Build/1`; on the wire `iface = "loomworks.Build"`,
  `v = 1`. `loomworks.*` is reserved for core and `lw.internal.*` for
  same-build facilities that are never a stable contract. A module's
  namespace is its module id; the registry refuses a module interface outside
  it, so two plugins cannot collide. Each editor view is an interface of its
  own (`loomworks.view.<Name>`), versioned on its own.
- Objects are paths naming **services, never entities**: `/` (the root), the
  core services `/workspace`, `/profiles`, `/projects`, `/build`, `/tests`,
  `/launch`, `/lsp`, `/debug`, `/tasks`, `/toolchains`, `/devices`,
  `/health`, `/maintenance`, `/views`, `/internal`, and `/modules/<id>` for
  each module.
- Methods, signals and error codes are `snake_case`; a module's own error codes
  are prefixed with its namespace (`<id>.<code>`).

**The root object.** Object `/` always implements `loomworks.Root/1`, which is
frozen (§19.8): it is never versioned past 1, gaining only optional fields
and new methods, which a client calls only after seeing them in
`describe().root_methods`.

| Method | Params | Result |
|--|--|--|
| `describe` | `{}` | `binary { lw_version, impl, dev }`, `transport { min, max }`, `session_generation`, `objects` — per object its `path`, `owner` (`core` or the module id) and `interfaces`, each `{ name, versions, deprecated?, internal?, same_build?, schema_digest }` (`schema_digest` maps a version to the sha256 of its schema document) — `root_methods`, and `delivery?`: `"subscription"` when the daemon sends a transport-11 connection task frames and changes only through its subscriptions (step 5g.3); absent (an older daemon) means it also sends the protocol-10 broadcasts |
| `schema` | `{ iface, v }` | that interface version's schema document |
| `subscribe` | `{ object, iface, v, signals?, args? }` | `{ sub_id, seq, initial? }` — `seq` is the baseline: the last `seq` of that object sent to this connection (0: none), so the subscription's first signal is `seq + 1` |
| `unsubscribe` | `{ sub_id }` | `{}` |

The root's signals reach every authenticated connection without a
subscription: `objects_changed { added, removed }` (paths; a module loaded,
the workspace loaded or unloaded) and `retiring` (§19.11). `welcome` carries
`objects`, the `describe().objects` list without digests, so a client with
nothing else to ask needs no extra round trip; a daemon that has not loaded
its workspace lists the objects that need none and sends `objects_changed`
when it loads.

**Version choice.** For each interface it uses, a client takes the highest
version it supports among the object's `versions`, and stamps that version on
**every call and every subscription**; the daemon keeps no per-connection
version state, so a reconnect only re-runs discovery. With no common version
the client degrades the feature that needs the interface (§19.16), never the
connection. An interface flagged `same_build` is callable only when the
client's `hello.lw_version` equals the daemon's; otherwise the call fails
with `same_build_required`.

**Message envelope.** After `welcome`, besides the frozen control subset
(§19.8), which stays as it is:

```
call   { kind = "call",   req_id, object, iface, v, method, args, env? }
ok     { kind = "ok",     req_id, result }
error  { kind = "error",  req_id, error = { code, message, data? } }
signal { kind = "signal", object, iface, v, name, sub_id?, seq?, args }
task   { kind = "task",   task_id, phase, ... }     -- §19.15
```

`env` is the client's environment, an envelope field because every method that
touches the model runs in it, under the one environment-scope rule of §19.15
(Environment). `args` are validated against the method's schema before the
handler runs; an invalid call is `invalid_args` naming the first violation.
Results and signals are validated in development builds and tests: a
violation fails the test, and is a log line in a release build.

**Errors and domain results.** `error` means only that the call could not be
processed. The operations' outcomes — `accepted`, `refused` (with message and
exit code), `declined` (with reason), `confirm` (with lines and plan) — are
**domain results** inside `result`, a union every interface shares. The
transport's error codes are `unknown_object`, `unknown_interface`,
`unsupported_version` (`data.versions` lists the offered ones),
`unknown_method`, `invalid_args`, `same_build_required`, `not_loaded` (the
method needs the workspace and loading it failed; `data` carries the header's
`state` and `error`, §19.13), `stopping`, `retiring`, `forbidden` and
`internal`. An interface declares its own codes in its schema. A stale
reference (a removed entity, an id of an earlier session generation) is the
method's `refused` / not-found result, never an error of the transport.
Once a mutating method's handler ran, its reply is never turned into an
error: a reply that does not match its schema (checked in development builds
and tests) is logged and sent as it is, because it may report what already
started (an accepted task), and an error would let a client run the
operation a second time. A non-mutating method's invalid reply may be
`internal` there.

**The CLI's calls.** Over transport 11 the CLI sends its operations and
reads as interface calls (`daemon/calls.lua`) and acts on a transport error
by its code: `unknown_object`, `unknown_interface`, `unknown_method`,
`unsupported_version` — nothing ran, so the protocol-10 request is sent
instead (a daemon of step 5g.1 speaks transport 11 without these
interfaces); `invalid_args`, `same_build_required`, `stopping`, `retiring` —
nothing ran, the command runs in-process (`declined`); `internal` or an
unknown code — for a mutating method, which may have started, the command
fails with exit 1 and is never run a second time in-process; for any other
method it runs in-process.

**References.** A request names an entity by a reference, `{ id }` or
`{ key }`. The editor sends ids taken from results and views; the CLI sends
the key the user typed, which the daemon resolves exactly as the in-process
command does (same messages and exit codes).

**Signals and subscriptions.** `Root.subscribe` registers a subscription of the
calling connection to one interface version of one object, optionally limited
to some of its signals and filtered by `args` as the interface defines (a
task id, a list of units). The daemon encodes that interface's signals at the
subscribed version and stamps them with the `sub_id`. An interface declares
per signal whether subscribing returns its full state as `initial` — every
view does, so subscribing after a reconnect re-hydrates the client. A
connection receives only the signals it subscribed to, plus the root's.
`seq` and `session_generation` follow §19.12: `seq` counts per object and
connection, over only the signals sent to that connection (gapless for it,
from the baseline `subscribe` returns), and a gap or a new generation means
"get the state again".

**Tasks and cancel.** A method its schema declares task-streamed runs as a
task owned by the calling connection, on the transport's task stream
(§19.15): the frames are not interface signals, because ownership,
back-pressure, observer bounds and disconnect-cancellation are shared by every
such method of every interface. The interface types the task's `meta` and its
`done.result`. Observers subscribe to `loomworks.Tasks/1`; only the owner may
cancel (`forbidden` otherwise); a disconnect still cancels. From transport 11
a `task_id` and a `sub_id` are opaque strings scoped to the session
generation, like entity ids (`loomworks.Common/1` `TaskId`); a connection of
protocol 10 keeps its integer task ids in its task frames, its `accepted`
replies and `status.tasks`, unchanged.

**Interface catalogue.** The first versions of the core interfaces, landed by
the steps of §19.19. Their schemas, not this table, are the full contract.

| Object | Interface | Methods (signals); T = task-streamed |
|--|--|--|
| `/` | `loomworks.Root/1` (frozen) | describe, schema, subscribe, unsubscribe (objects_changed, retiring) |
| — | `loomworks.Common/1` | shared types only: reference, id, outcome, environment, launch spec, debug spec, task meta |
| `/workspace` | `loomworks.Workspace/1` | header, trust_accept, publish, publish_one, revert_to_baseline, revert_one, set_intent, create, delete_user_prefs (changed, header_changed) |
| `/profiles` | `loomworks.Profiles/1` | list, set_active, add_tool, remove_tool, set_device, clear_device, query, compiler_cache |
| `/projects` | `loomworks.Projects/1` | add, remove, configuration add / rename / remove / save, launch_save, deploy_save, variable_set, description_set, type_config_set, expand_preview, candidates |
| `/projects` | `loomworks.ConfigSets/1` | add, update_mapping, generate_defaults |
| `/build` | `loomworks.Build/1` | build T, clean T, reset T |
| `/tests` | `loomworks.Tests/1` | discover T, run T |
| `/launch` | `loomworks.Launch/1` | prepare_run T, prepare_debug T, device_log |
| `/debug` | `loomworks.DebugConfig/1` | adapters, set_adapter, known_languages |
| `/lsp` | `loomworks.LspConfig/1` | get, compile_command, set_option (changed) |
| `/tasks` | `loomworks.Tasks/1` | list, cancel, attach (started, ended; task frames) |
| `/toolchains` | `loomworks.Toolchains/1` | list, rescan |
| `/toolchains` | `loomworks.Sdks/1` | list, add, remove, detect |
| `/devices` | `loomworks.Devices/1` | list, scan (changed) |
| `/health` | `loomworks.Health/1` | run |
| `/maintenance` | `loomworks.Maintenance/1` | orphaned, execute_deletion T, locks, unlock |
| `/views` | `loomworks.view.Header/1`, `.ProjectsIndex/1`, `.Workspace/1`, `.Tests/1`, `.Devices/1` (one interface each) | get (update; full state on subscribe) |
| `/internal` | `lw.internal.Snapshot/1` (same_build) | get |
| `/modules/<id>` | `<id>.<Name>/<v>` | defined by the module |

An interface whose surface grows unwieldy is split at its next version without
disturbing the clients of the others.

**Module interfaces.** A module provides an interface only for a feature core
has no abstraction for (a device log stream, signing setup); a feature core
abstracts (devices, toolchains, build steps) reaches clients through the core
interface, which the module feeds through the module interface of §8. A Lua
module declares its interfaces in its module table (`interfaces`: per
interface name and version, the path of its schema relative to the plugin, its
method handlers and its signals); its schemas ship with the module. When the
module is loaded (§8.0), each declared interface version is mounted on
`/modules/<id>` only if every method in its schema has a handler and every
handler a method in its schema; a mismatch rejects that interface version, not
the module, and is reported by `lw health`. Handlers receive a context
(environment, reply, task start, signal emission, reference resolution),
never the connection. The wire version of a module interface is independent of
the in-process module API version (§8.0).

**Providers (reserved).** A daemon not written in Lua hosts modules **out of
process**: a provider is spawned by the daemon (`<provider> --stdio`) or
connects with `hello.role = "provider"`, and registers its objects and their
schemas through `loomworks.Provider/1.register`. The daemon routes calls for
`/modules/<id>` to it and forwards its signals and task frames; the task stays
owned by the calling client connection, the provider only produces its events.
The core's module contract for such a provider (detection, configure and build
steps, language-server configuration) is the interface
`loomworks.ModuleProvider/1`, which the daemon calls. The role, these two
interface names and the routing rule are reserved; nothing else of providers
is specified until they are built.

**Schemas and conformance.** Each interface version has one schema document:
JSON Schema (2020-12) for parameters, results, signal payloads and shared
definitions, in an envelope naming the interface, version and status and, per
method, its parameters, result, optional task meta and result, errors, whether
it needs the client environment and whether it mutates, and per interface the
schema of a subscription's `args` (`subscribe_args`; without one a
subscription takes no `args`). Documents use only a
restricted keyword set (`type`, `properties`, `required`,
`additionalProperties`, `items`, `enum`, `const`, `oneOf`, `$ref`, `$defs`,
`minimum`, `maximum`, `pattern`, `description`) that every validator
implements identically. Core's documents live in this repository's protocol
schema directory, together with the transport document, golden transcripts
and the frozen snapshot of every interface version a stable release
shipped; after the split they move to a separate protocol repository, tagged
and pinned by both the binary and the plugin. A module's documents live in its
own repository. The contract is enforced by:

- a **lint**: every document is valid against the meta-schema and uses only the
  allowed keywords;
- an **additive ratchet**: against its frozen snapshot, a version's parameters
  (method `params`, `subscribe_args`, and the transport frames a client sends)
  may only gain optional properties and enum values, its results and signals
  only gain properties, enum values and alternatives; nothing is removed
  (including an enum value), renamed, retyped or made required. Anything else
  is a new version. A client that sends a parameter value added
  after the version first shipped checks the interface's `schema_digest` (or
  the daemon's version) first, since an older daemon refuses it as
  `invalid_args`;
- **registry and schema agreement**: every mounted interface version has a
  document with the published digest, every method a handler, every version
  older than the newest an adapter;
- **server conformance**: golden transcripts, driven against any binary over
  the standard-I/O transport — the Lua daemon and any rewrite alike;
- **client conformance**: the plugin's client against the same transcripts,
  replayed, for every interface version it claims.

**Transcripts.** A transcript file, `transcripts/<namespace>/<Rest>.<v>.json`
beside the interface's schema and checked by `meta/transcript.schema.json`, is
`{ transcripts = 1, interface, version, description, cases }`. A case
(`name`, `description?`, `fixture?`, `hello?`, `handshake?`, `allow?`,
`steps`) runs on a fresh daemon over one connection, on a workspace the
runner prepares (`fixture`: `empty`, the default, or `shell`, a shell project
`app` with configuration `Debug`, the configuration set and trusted profile
`dev` and a launch configuration `hello`). Unless `handshake` is false the
runner sends `hello` (the case's `hello` fields over the default) and binds
the `welcome` as the variable `welcome`; `lw_version`, `env` (the client
environment to send) and `root` are bound before. A step is `send` (a frame
template, validated against the transport unless `malformed`), `expect` (the
earliest unconsumed received frame its selector — `kind` and the literal
`req_id`, `object`, `iface`, `name`, `sub_id`, `task_id`, `phase` — picks
must match the pattern, within `timeout_ms`) or `expect_none` (no frame the
selector picks arrives `within_ms`); frames of other streams interleave
freely, and at the end every received frame must have been consumed or match
an `allow` pattern. Patterns are partial (an object names the fields it
checks, an array has the actual length); an object whose keys all start with
`$` is a matcher: `$any`, `$type`, `$absent`, `$bind` (bind or compare a
variable), `$var` (a bound value, with `$with` merged over it in a
template), `$contains`, `$exact`, `$pattern`, `$len`, combinable. The runner
validates every received frame: transport frames against the transport
document, an interface call's `ok` against its result schema and its `error`
code against the transport's and the method's codes, a signal against its
schema with a gapless `seq` per object, none for a subscription after its
`unsubscribe` and its `session_generation` (if any) the `welcome`'s, every
task's frames in order (`start` first, nothing after `done`; integer ids at
protocol 10, strings from 11) and the task frames of a task-streamed call
(the start meta naming the method; `done.result` against its task result
schema); a protocol-10 reply is checked against its v0 shape
(`transport.json` `v0.replies`), so the v0 aliases provably stay unchanged;
other protocol-10 frames are only matched. An explicit `null` is a present
value (`$absent` fails on it, `$any` accepts it), and an object pattern never
matches an array nor an array pattern an object.

Clients **must tolerate** unknown fields, unknown enum values and unknown
alternatives in results and signals (an unknown value is shown as unknown or
neutral, never a failure), so an interface may add a field, a state or an
outcome without a new version.

**Versions and deprecation.** Within an interface version only additive changes
are allowed. A breaking change makes version `N+1`; the daemon keeps serving
`N` through an adapter over `N+1` — never a second implementation — and
announces `N` in `describe().deprecated` and on the editor's Runtime line. A
deprecated version, and a transport version below a raised `protocol_min`, is
dropped no earlier than **two stable releases and at least 60 days** after the
first stable release that deprecated it.
