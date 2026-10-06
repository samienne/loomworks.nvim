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
and routes the operations that have moved (§19.19); all other operations run
on the in-process path. When the default flips, `in-process` is accepted as a
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
`config get`, `lw tools`; §19.13, §19.14) read the projection the same
selection serves: the shared daemon's, or the loopback runtime's. The
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
heartbeat alone. A holder that holds a build-directory lock across
several steps rewrites the record's operation when it moves from configure to
build, so recovery knows which step was interrupted. A record without a start time (written by an older
version) is judged by heartbeat alone.

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
   is skipped.
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
endpoint, same_key } ] }` (absent values are `null`), sorted by root.

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
header, §19.13, §19.14); the rest of the
broadcasts #88.*

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
is end-of-stream to the other.

**Frozen control subset.** Framing, `hello`/`challenge`/`auth`/`welcome`,
`ping`, `status`, `stop` and `retire` (§19.9) never change shape across
versions, so any two versions can always authenticate, inspect and retire each
other.

### 19.9 Version handshake

*Status: master (`daemon/version.lua`, `daemon/ensure.lua`), applied by every
workspace command in `daemon` mode. During the transition a version-bypass
run is the in-process path, and a daemon with newer schemas is reported in
one line and not used — the command itself still runs in-process, where the
file-level checks of §2.7 apply.*

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

- **Idle daemon** (no client other than this one and observers, no running
  task) — the client stops it (§19.11) and launches its own binary in its
  place; observers never count as busy.
- **Busy daemon** — the client sends `retire`: the daemon accepts no new
  operations from mismatched clients, keeps serving its attached clients, and
  exits as soon as it is idle; the next command launches the current binary.
  The client runs **this** command as a **version-bypass run**: attached, but
  without the runtime lock (§19.2), holding only its operation locks (§19.3),
  and prints one line:

  ```
  lw: the workspace daemon runs lw v0.1.43 and is busy — running this command without it; it restarts when idle
  ```

A client never stops a busy daemon, and never drives a daemon it does not
match. A daemon whose schemas are newer than the client's is never stopped by
it; the client refuses with the update message of §2.7 "Reading a newer file".

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

### 19.11 Lifetime

*Status: master (`daemon/server.lua`, `daemon/command.lua`). A `lw` command
connects for a moment (handshake, `ping`) and leaves; the keepalive rule
applies to every authenticated connection, except one that owns a running
operation (§19.15). A running build makes the daemon busy (handle `busy`); a
`retire`d daemon exits when it has no authenticated client and no running
build.*

- **Attached clients keep it alive.** A connection counts while authenticated
  and open. The editor sends a keepalive `ping` (about every 30 s); a
  connection silent for three intervals is dropped as half-open.
- **Observers and retirement.** A `retire`d daemon broadcasts `retiring` to
  every connected observer (§19.16), and `welcome` carries `retiring` for one
  that connects later; an observer then disconnects and does not reconnect to
  that daemon. Observer connections never hold off retirement: a retiring
  daemon exits once it has no running build and no authenticated client other
  than observers. (They still count for the idle timeout and in `clients`.)
  `status` reports `observers`, the number of observer connections, and
  `tasks`: one `{ task_id, name, kind, profile, units, origin, started_at,
  percent? }` per running task — its `start` meta (§19.15), the wall-clock
  time it started, and its last progress percent, absent before the first
  tick. An addition to the frozen `status` shape (§19.8): a daemon of an
  older protocol omits it.
- **Idle exit.** With no connection, no running task and no request for the
  idle timeout — setting `daemon-idle-timeout`, default 1 hour — the daemon
  exits.
- **Root removed.** On each heartbeat the daemon checks its workspace root; if
  it is gone, it cancels running tasks and exits.
- **Lost lock** — §19.2.
- **Exit** of any kind cancels running tasks (their clients see the
  cancellation of §19.15), releases operation locks and the runtime lock,
  removes the handle and (POSIX) the socket, and ends the process — no timer or
  handle may keep it alive.

**Commands.** `lw daemon status` reads the handle and lock and, for a live
same-host daemon, asks it for `status` (clients, running operations, versions);
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
generation). Snapshots carry a current-key → id index from which a client
builds its id↔key map, a transport-layer router that domain logic never
consults.

Every model change advances a per-workspace sequence number and broadcasts a
typed `model_change` stamped with seq and session generation to every
authenticated client. A client re-pulls the affected scope snapshot (coarse
invalidation); a broadcast at or below its seq is ignored, a newer one
arriving mid-refresh schedules exactly one more re-pull, and a new session
generation forces a full re-hydrate. Per-object deltas are a future
optimization.

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
environment, as for a routed operation (§19.15), in which the daemon loads
or re-validates its workspace before answering. The reply is `ok` with
`outcome = "ok"` and:

- `config` (scope `config`): the published baseline as the daemon loaded it
  from `loomworks.json` (parsed, program-bearing fields stripped, §17.6);
- `user` (scope `user`): the working copy as the model serializes it for
  `loomworks.user.json`, with its schema `_meta`;
- `cache` (scope `cache`): the cache as the model serializes it for
  `loomworks.cache.json`, with its schema `_meta`;
- always: `tools` (the resolved toolchain detection the model holds),
  `shared_ignored` (the stripped program-bearing fields, §17.6), `index`
  (the current-key → id index of §19.12: `projects`, `config_sets`,
  `profiles` and `config_units`, each key → id), `seq` and
  `session_generation`.

A scope the request does not name is absent. A workspace the daemon cannot
load is answered `outcome = "refused"` (`message`), and a request it does not
carry (stopping, malformed, another environment while a build runs)
`outcome = "declined"` (`reason`), as for a routed operation. A snapshot takes
no lock, starts no task and writes nothing. A client builds its projection
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
model nor any file. The registry starts with `tools` (the toolchains each
module type detects in the client's environment: `result.tools`, module type
→ list of `{ key, label, tool_data }`) and `profile_cache` (`args.profile`
and `args.project`, keys: `result.cache`, the compiler cache that profile
resolves for that project as `lw profile query … cache` prints it).

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
Reset, step 5d); other operations future.*

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
disconnects (Ctrl-C ends `lw`: the interrupt handler drops the connection,
which is the cancellation, and exits 130), the daemon stops (`lw daemon stop`, idle,
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
`daemon/host_binary.lua`, `daemon/remote_task.lua`); remote tasks shown as
local ones (Running state, Joining late, End, UI below), the origin marker
and the version-mismatch note (`daemon/observer.lua` `mismatch_note`); commands
and the attached editor future.*

**End state.** The editor uses the **same daemon as the CLI**. It connects,
authenticates and holds a keepalive (§19.11). Operations move from the editor
to commands in the order of §19.19. With no host binary, the editor runs the
daemon code inside its own process over the loopback transport, taking the
runtime lock as an attached run (§19.2) for as long as its workspace is
loaded. *(Future:)* such an attached editor also serves the endpoint. It is
then the workspace's shared daemon, owned by the editor process, and CLI
clients connect to it instead of being refused as busy. It ends when the
editor closes the workspace.

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

- **Host binary.** The observer resolves a host binary in this order:
  - `LOOMWORKS_LW` (an existing file);
  - the repository pin (§16.21): the pinned version's host binary already
    provisioned in the per-user pinned cache (§16.22) — the editor never
    downloads one, and does not re-hash a file the provisioning host verified;
  - `lw` on the search path (on Windows an `.exe`).

  With none, the status page shows one inline note (no host binary: running
  in-process). The editor never launches a daemon from its own plugin source,
  and runs no loopback runtime until the thin-client part of §19.19 step 5
  (the CLI's attached runs of step 5e do not include the editor). It still watches for a
  daemon another client starts and observes that one.
- **Launch.** The observer launches `<binary> daemon run --root <root>`
  (§19.10: detached, no inherited handles, the state directory as working
  directory) only when no daemon is live on workspace load or on an explicit
  `:LoomworksDaemon connect`, and once after a retirement (below). Readiness is not awaited in a blocking wait: the
  observer watches the handle. An early exit other than "another daemon won"
  is a note. A daemon that is starting, hung, of another host, or attached is
  not launched over; the observer notes it and watches.
- **Connect.** The observer handshakes as `client = "editor"`,
  `role = "observer"`. It observes a daemon whose protocol equals its own and
  whose schemas are not newer (§19.9; the host version may differ).
  - **Incompatible daemon.** The observer notes it (protocol or schemas) and
    closes. It neither restarts nor retires that daemon, and does not connect
    to it again.
  - **Keepalive.** While connected it sends `ping` about every 30 s.
- **No relaunch after a stop.** When the connection drops because the daemon
  stopped (`lw daemon stop`), crashed or dropped this observer, the observer
  never launches a daemon by itself. This keeps `lw daemon stop` meaningful.
  It watches the handle (about every 2 s) and connects again when a live
  daemon appears. It skips one it was told is `retiring` or found
  incompatible, identified by pid and start time.
- **Retiring.** On `retiring` (broadcast, or in `welcome`) the observer
  disconnects at once, so a version change completes (§19.11). Once that
  daemon has exited and no other daemon is live, the observer launches one
  daemon itself (one attempt, not a loop: an early exit is a note) and
  connects to it; a successor another client started first is observed
  instead.
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
  keeps running (§19.11).
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
update the plugin or the pin — running in-process`.

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
     editor's loopback runtime comes with the thin-client part of this step.
6. **Default flips** to shared daemon mode, after the criteria in DAEMON.md; the
   in-process path remains only as attached (`--no-daemon`) mode.
