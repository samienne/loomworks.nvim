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
`runtime.mode` (informational until §19.19 step 4) — and the selection of
attached by `--no-daemon`, `LOOMWORKS_NO_DAEMON` and `CI`
(`daemon/runtime.lua`); the end-state values future.*

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
(§19.10). Otherwise the command runs shared. An invalid configured value is
reported and ignored (falls through to the next source).

The editor selects the same way from its setup option `runtime.mode`, and runs
attached inside the editor process when it has no host binary (§19.16).

**During the transition** the setting `runtime-mode` takes `in-process` (the
default) or `daemon`, with `LOOMWORKS_RUNTIME` as the environment override. In
`in-process` mode no daemon is launched or used. In `daemon` mode every
workspace command ensures the daemon is running (launching it if absent)
and routes the operations that have moved (§19.19); all other operations run
on the in-process path. `--no-daemon` during the transition means "launch and
use no daemon" — the in-process path — until the loopback transport exists
(§19.19 step 5). When the default flips, `in-process` is accepted as a synonym
of `no-daemon`.

### 19.2 One runtime per workspace: the runtime lock

*Status: master for daemons (`daemon/rlock.lua`, the §19.5 record plus
`mode`, `command`, `host_version`; held by `daemon/server.lua` for its
lifetime, a held lock makes `lw daemon run` exit with status 3, a replaced
record makes the daemon exit 1); attached runs future.*

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
  is *launched*). If another attached run holds it, the client waits briefly
  (setting `runtime-busy-wait`, default about 5 s) and then fails cleanly:

  ```
  lw: workspace busy: lw build (pid 4242 on HOST) is running here without a daemon — retry when it finishes
  ```

  Exit status 1. Never a second writer. Parallel jobs that must not wait for
  each other use separate checkouts. A hung holder is reported as hung, not
  busy (§19.5).
- A holder that finds its lock record replaced (its lock was reclaimed while it
  was suspended) has lost authority: it stops at once, writes no workspace
  file, and exits nonzero.
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
within a class in a canonical order: build directories by normalized path
(§2.3 normalization), devices by serial, files in the order
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
unchanged); the editor shows an error notification. `lw unlock --workspace`
(and `lw unlock --all`, §16.6) also clears an O lock whose holder is gone, and
`--force` one whose holder runs; dead and hung holders of every class are
handled by §19.5 (`--break-locks`, accepted by every command above).

O is re-entrant within one process: an operation that holds it (the CLI's
`lw reset`, which takes O and then every build lock before the workspace's
deletion runs) may call another operation that takes it; the lockfile goes
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
by `daemon/server.lua`), the Runtime row and `lw daemon status`.*

A daemon publishes `<root>/.nvim/loomworks.daemon.json` after binding its
endpoint: `{ pid, host, os, start_time, endpoint, protocol, lw_version,
schemas = { user, cache }, session_generation, started_at, clients, busy,
idle_since, lock_nonce }` (`start_time` is the daemon's process start time of
§19.5, `lock_nonce` its runtime-lock record's nonce). A development build's
`lw_version` is its source fingerprint (§19.9). It
refreshes the file's modification time on its heartbeat and rewrites it when
`clients`/`busy` change. Liveness is judged by the heartbeat, never by probing
the pid (§16.6). The handle is **discovery only**: the runtime lock (§19.2)
decides who the runtime is, and the handshake (§19.8) decides whether a client
may use it. A malformed handle is reported as unreadable, never as a live
daemon. A daemon that finds its handle removed while it runs rewrites it.

**Runtime row.** `lw status` shows one `Runtime` line computed **only** from the
handle and the runtime lock — it never launches or connects:

```
Runtime   daemon pid 4242, 2 clients, idle 12m
Runtime   daemon pid 4242, v0.1.43 (this lw is v0.1.44 — restarts when idle)
Runtime   daemon on OTHERHOST (pid 4242)
Runtime   attached: lw build (pid 4242)
Runtime   no daemon (starts on the next command)
Runtime   in-process
Runtime   stale daemon handle (pid 4242, 3h ago) — lw daemon stop clears it
Runtime   daemon pid 4242 is not responding (no heartbeat for 2m) — lw daemon stop --force
Runtime   daemon pid 4242 (starting)
Runtime   unreadable daemon handle — lw daemon stop clears it
```

`no daemon (starts on the next command)` is shown in `daemon` mode,
`in-process` in `in-process` mode, when neither the runtime lock nor a handle
exists.

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
  A stale socket file is unlinked only while holding the runtime lock.
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
`daemon/client.lua`; protocol version 2); broadcasts #88.*

**Framing.** A message is a JSON object prefixed by its decimal byte length
and a newline (`<len>\n<json>`). Every request carries a `req_id` that its
reply echoes; broadcasts carry none. An unknown kind, a malformed frame or a
handler error yields a typed error reply, never a crash.

**Authentication** (mutual, before anything else). Let *K* =
HMAC-SHA256(machine key §17.2, `"loomworks-daemon-v1"`), and *E* the endpoint
address from the handle.

1. client → `hello { protocol, lw_version, schemas, client = cli|editor, nonce = Nc }`
2. daemon → `challenge { protocol, lw_version, schemas, session_generation,
   server_nonce = Ns, server_proof = HMAC(K, "server\n" .. E .. "\n" .. Nc .. "\n" .. Ns) }`
3. client verifies `server_proof`; on failure it closes the connection without
   sending anything else and reports the endpoint as untrusted. Otherwise →
   `auth { client_proof = HMAC(K, "client\n" .. E .. "\n" .. Ns .. "\n" .. Nc) }`
4. daemon verifies → `welcome { header, seq, clients, busy }` (§19.13).

Nonces are 32 random bytes (hex); proofs are compared in constant time. Before
`welcome` the daemon accepts only `hello` and `auth`, caps a frame at 64 KiB
(a longer length prefix closes the connection before the payload is read),
closes a connection that has not authenticated within about 5 s, and sends no
broadcast to it. A failed proof closes the connection with no detail. Because
the server proves knowledge of *K* first, a process squatting the endpoint
cannot impersonate the daemon to a client. The loopback transport (§19.1) skips
authentication; it never leaves the process.

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
(a development build compares its source fingerprint as its version). An editor
client matches when protocol and schemas are equal (its own code ships with the
plugin, §19.16).

On a mismatch, after authenticating:

- **Idle daemon** (no other client, no running task) — the client stops it
  (§19.11) and launches its own binary in its place.
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
a second, once, before running without it. A `lw daemon run` that finds the runtime lock
held exits with status 3, which the launching client reads as "another daemon
won".*

A client that finds no live daemon (no handle, a stale handle, or a lock whose
holder is gone) launches `<own executable> daemon run --root <root>`:

- **Detached**, in a new process group/session, with **no inherited standard
  handles** (on Windows, standard input, output and error are not inherited;
  on POSIX they are `/dev/null`); the daemon writes its own **runtime log** to
  the per-user state directory, one file per workspace (named by the root
  hash), capped at a few megabytes with one rotated predecessor.
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
applies to every authenticated connection. A `retire`d daemon exits when its
last authenticated client disconnects (there are no tasks in step 2).*

- **Attached clients keep it alive.** A connection counts while authenticated
  and open. The editor sends a keepalive `ping` (about every 30 s); a
  connection silent for three intervals is dropped as half-open.
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
`lw daemon stop --force` as the remedy. `lw daemon stop --force` and
`lw daemon kill` are the forced recovery of §19.5. Stopping when no daemon runs
succeeds with nothing to do. A daemon on another host is never stopped or
killed from here (the command names the host); a stale one is reclaimed per
§19.5. `lw daemon restart` is stop then launch (`--force` applies to the
stop). None of these require the
workspace to load.

### 19.12 Wire identity and change broadcasts

*Status: #88.*

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

*Status: #88.*

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

### 19.14 Commands

*Status: #88 (mutation commands); the set of commands grows per §19.19.*

A mutation is a **command** the daemon applies to its model with the
operation's locks (§19.3) and persists. Commands are FIFO-serialized: a
command's `model_change` broadcast precedes any later command's and precedes
its own acknowledgement, which carries only the outcome (`ok`, `rolled-back`,
`partially-applied`) or an error. Wire arguments (semantic keys) are resolved
to domain objects at the serialization boundary; domain logic stays
reference-based. Read-only queries run on the client's projection.

### 19.15 Task stream and delegated operations

*Status: #88 for `lw build <profile> [-- args]`; other forms and operations
future.*

A running operation streams `progress`, `output` and `notify` events on a
**task stream**, separate from model changes and observable by every
connected client (a build started by the CLI streams into the editor). The
stream coalesces progress (a tick only when the integer percent advances) and
bounds output per task (a single truncation notice past the cap); model
changes are never dropped. The durable outcome arrives as a `model_change`.

**Same behaviour.** An operation run in the daemon is behaviorally identical to
the in-process operation it replaces — the same step sequence, locks, gates,
status lines, cache write-back, failure lines and exit codes — differing only
in how a step is spawned (streamed) and how a refusal travels (on the stream,
printed by the client exactly as the in-process host prints it). For a build
this is the shared build-step sequence of §16.4 / §16.6 / §16.28 / §5.1 / §5.10.

**Live workspace.** Before accepting an operation the daemon applies every
pending external change to its files exactly as its file watcher would
(including trust refusal, §17.4), then resolves arguments as the in-process
host does (§16.9).

**Cancellation.** An operation belongs to its client. When that client
disconnects, the daemon stops, or the workspace or the operation's subject is
unloaded/removed, the daemon terminates the running step's process tree,
records nothing for that step, releases its locks and ends the task nonzero. A
client that loses the connection after its operation was accepted reports a
failure; it never re-runs the operation another way.

**Routing.** A client routes an operation to the daemon only when the daemon
carries every argument form the client was given; any other form runs on the
in-process path (transition) and a workspace the machine would refuse (§17.4)
is never routed. While the daemon is opt-in, a routed operation prints one dim
line before its output — `lw: building through the workspace daemon (pid N)` —
which is removed when the default flips.

### 19.16 The editor as a client

*Status: future (§19.19 step 4).*

The editor uses the **same daemon as the CLI**: it resolves a host binary with
the broker precedence of the runtime
resolution (`LOOMWORKS_LW`, the repository pin §16.21, `lw` on the search path,
a previously provisioned runtime; never a fetch), launches `lw daemon run` from
it when no daemon is live (§19.10), connects, authenticates and holds a
keepalive (§19.11). In the first editor step it **observes** only — task
streams and model changes from operations started elsewhere — while running
its own operations in-process; operations then move to commands in the order
of §19.19. With no host binary, the editor runs the daemon code inside its own
process over the loopback transport, taking the runtime lock as an attached
run (§19.2) for as long as its workspace is loaded. *(Future:)* such an
attached editor also serves the endpoint — it is then the workspace's shared
daemon, owned by the editor process, and CLI clients connect to it instead of
being refused as busy; it ends when the editor closes the workspace. A version mismatch it
cannot repair by restarting (its plugin code and the resolved binary differ in
protocol or schema) is shown inline and handled as a version-bypass run
(§19.9); the editor does not launch the daemon from its own plugin source.

### 19.17 Parity

*Status: #88 (build).*

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
3. **First operation** — `lw build` routed to the daemon (§19.15).
4. **Editor connects** — observer + keepalive (§19.16).
5. **Remaining operations**, one at a time, each with a parity test (§19.17);
   then the loopback transport, so attached runs use the same code; then the
   CLI and the editor stop loading the workspace themselves.
6. **Default flips** to shared daemon mode, after the criteria in DAEMON.md; the
   in-process path remains only as attached (`--no-daemon`) mode.
