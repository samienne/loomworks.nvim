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

*Status: future (the `runtime-mode` setting and `LOOMWORKS_RUNTIME` exist on
#88 with values `in-process|daemon|auto`; re-cut).*

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

*Status: #88 (`daemon/lock.lua`, `.nvim/loomworks.daemon.lock`, held by the
daemon for its lifetime); re-cut (attached runs, holder record, lost-lock
exit).*

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

*Status: master for build-directory locks (§16.6), device locks (§18.7) and
per-file save locks (§2.7); future for the workspace operation lock, the lock
order, and `lw nuke` taking build locks. This is step 1 of §19.19 and comes
before any lifetime work.*

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
record `{ pid, host, operation, started_at, nonce }`. It is taken by every
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
unchanged); the editor shows an error notification. `lw unlock` (§16.6) also
clears a stale O lock; dead and hung holders of every class are handled by
§19.5 (`--break-locks`).

### 19.4 Crash-consistent multi-file commits

*Status: future (step 1 of §19.19).*

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
named and the remedies to discard it (`lw unlock --journal`) or reset.

**Validation.** A journal is data from disk: it is honoured only when every
entry names one of the three workspace files in `.nvim/` and the staged files
match `<file>.txn-<hex id>` beside them; anything else refuses the workspace
as above. Rolling forward never bypasses trust — the renamed files are verified
on load as any file is (§17.4).

**Build trees.** Removing build directories (nuke, reset, deletion) is not
journalled; it keeps the existing crash rule — cache entries are marked
`unknown`/deleting before the removal starts and removed only after it
succeeds (§5.7, §15 invariant 1) — and the cache change that follows is then
committed as above.

**Older versions** neither take O nor read the journal; one that reads a
workspace between a crash and the next recovery can see a partially applied
commit. This is the same class of residual race as §2.7 "Remaining race".

### 19.5 Recovery from dead and hung holders

*Status: future, except the stale-heartbeat reclaim of build-directory and
device locks (§16.6, §18.7) and `lw unlock` (master). Lands with step 1 of
§19.19 for the operation locks and with step 2 for the runtime.*

A crashed or killed process must never leave a workspace stuck, and a hung one
must be recoverable with one command. These rules apply uniformly to every lock
of §19.3 (R, O, B, D, F) and to the handle file and socket (§19.6–§19.7).

**Lock record.** Every lock record carries: process id, host name, the
holder's **process start time** (as reported by the operating system; it
distinguishes a reused process id), a random nonce, the holder kind (`lw`,
`daemon`, or `editor`), the operation, and a start timestamp; its modification
time is the heartbeat. A holder that holds a build-directory lock across
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
2. **Kill** the holder's process tree — the daemon's process group, or the
   holder and its enumerated descendants (on Windows a forced tree
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

*Status: #88 (`daemon/handle.lua`); re-cut (fields).*

A daemon publishes `<root>/.nvim/loomworks.daemon.json` after binding its
endpoint: `{ pid, host, os, endpoint, protocol, lw_version, schemas = { user,
cache }, session_generation, started_at, clients, busy, idle_since }`. It
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
```

### 19.7 Endpoint and access control

*Status: #88 for the POSIX socket directory and a default-security named pipe;
future for the Windows DACL.*

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

Clients never compute the address; they read it from the handle.

### 19.8 Wire protocol and authentication

*Status: framing, request/reply and broadcasts #88; authentication future.*

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

*Status: future (#88 negotiates a protocol range; re-cut).*

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

*Status: #88 has a minimal launch (`cli._spawn_daemon_if_possible`); re-cut to
the recipe below.*

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

*Status: #88 for idle exit (10 min) and `lw daemon status|stop`; future for the
rest.*

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
5g.3 (`daemon/observer.lua` `_subscribe`); no editor fallbacks
("Availability"), step 5s, *done*; the views
and operations steps 5j–5o (§19.19), *done*; the editor without a model of
its own in `daemon` mode ("End state", "Public API"), step 6b-α, plan; its
"Load warnings", step 6b-α part F, *done*; the connection through the `--stdio`
relay, step 5i PR G: its spec (PR G0) *done*; the relay transport and
lifecycle ("Through the relay" except "Skipping an incompatible daemon",
`--retiring`) PR G1, *done* (`daemon/client.lua` `relay`, `daemon/observer.lua`
`_spawn` / `_on_relay`); the incompatible-daemon policy over the relay
("Skipping an incompatible daemon", retirement only over `via = "relay"`)
PR G2, *done* (`daemon/observer.lua` `_skip`, `_weigh_retire`). From G1 the observer no longer watches the handle or
launches a daemon itself ("Step 4" below marks what G1 superseded). The editor-owned child daemon of the
earlier plan (step 5p) is dropped.*

**End state.** *(Step 5i, done; the editor without a model of its own,
step 6b-α, plan.)* The editor is a **pure `lw` client**
of the **same daemon as the CLI**. It spawns `lw daemon run --root <root>
--stdio`, which connects to the workspace's shared daemon or starts it first
(§19.10 "Connections"), and speaks the protocol through that relay; it reads
none of lw's internal files to connect, launch or follow a daemon, and holds
a keepalive (§19.11). Only diagnostics may still read them, read-only:
`:LoomworksDaemon status` and `:checkhealth loomworks` may inspect the
handle, the runtime lock and the daemon logs to describe what they find;
nothing they read decides whether, when or to what the editor connects, and
they never write, remove or lock anything there. The relay needs a host
binary ("Host binary" below): with none the editor spawns no relay and runs
**degraded**: the status page shows the workspace unloaded with the reason,
language servers it manages are withheld ("LSP configuration" below),
operations are refused with that reason ("Availability" below), and nothing
of the workspace is loaded or run in the editor; it does not observe a
daemon another client started. **In `daemon` mode the editor holds no
workspace model**, connected or not (step 6b-α): it loads none, detects no
toolchains or build targets, runs no file tracker on the workspace's files,
writes none of them (the cache included) and builds no view in-process.
Everything it shows comes from the daemon's views and replies, and every
public function answers from them ("Public API" below). Its tasks are
owned by its connection, so an editor that quits or crashes leaves no task
running; the daemon itself outlives it under §19.11. Operations move from the
editor to commands in the order of §19.19. When the shared daemon cannot be
started, the editor reports it and runs degraded (step 5s); there is no
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

With no host binary the editor spawns no relay of any form and runs
degraded ("End state").

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
  equality: the relay itself applies no version policy and never restarts a
  daemon on its own; only the editor's retirement does. The editor's `retire` goes over
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
  means: the editor stays degraded with that note and spawns no further
  relay until an explicit `:LoomworksDaemon connect` (or a workspace
  reload).

  | Status | Note | Follow-up |
  |--|--|--|
  | 10 | could not start the workspace daemon; the editor runs degraded (step 5s) | one no-launch relay, then wait |
  | 11 | the workspace daemon is not responding | one no-launch relay, then wait |
  | 12 | the daemon belongs to another loomworks data dir, or is not a loomworks daemon | wait |
  | 13 | the workspace daemon runs on another host | wait |
  | 14 | a retiring daemon is still busy | a retiring relay, or a no-launch relay ("Following a stopped or retiring daemon" below) |
  | 16 | the retiring daemon has exited and no other is live | the retirement episode's one ordinary relay, else wait |
  | 3 | the pinned `lw` predates the shared-daemon relay and another runtime holds this workspace (an older pin's attached `--stdio`, §19.10 "Compatibility"); running degraded — update the pin | wait |
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
  an incompatible daemon") — it closes that relay, stays degraded, and
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
  that relay and stays degraded for the session; it spawns no skip relay,
  and retries only on `:LoomworksDaemon connect`.

**Interface client.** *(Step 5g.3: discovery through `Root.describe` with
`welcome.objects` as the fallback, the `/tasks` and `/workspace`
subscriptions, `objects_changed` and the per-feature note; the views and
operations: done, steps 5j–5o — the `/views` features of step 5j specified,
part 0, and implemented, part C.)* On every connect, including
each reconnect, the editor **discovers** the daemon through the root object
(`welcome.objects`, `Root.describe`; §19.20), picks per interface the highest
version both sides support, and subscribes to the views and tasks it shows,
taking their full state from each subscription's `initial`. A missing or
incompatible interface degrades only the feature that needs it, with one
Runtime-line note naming the interface and both versions (e.g. `lsp
configuration: daemon offers loomworks.LspConfig/2, editor needs /1`); it
never fails the connection or the other features. The features of step 5j
are `statusline` (`loomworks.view.Header/1`) and `project index`
(`loomworks.view.ProjectsIndex/1`), beside `tasks` and `model changes`; a
degraded view is built in-process (§19.13 "Two sources, one shape";
in `daemon` mode shown unavailable instead, never built in-process). Step 5k
adds `operations` (`loomworks.Build/1` with `configure`, `units`, `jobs` and
qualified targets), `launch` (`loomworks.Launch/1` with `prepare_debug` and
`build_scope`), `debug adapters` (`loomworks.DebugConfig/1`) and, in `tasks`,
`Tasks/1.cancel` and `list`; a degraded one refuses its operations, never
running them in-process ("Availability" below). Step 5l adds `lsp configuration`
(`loomworks.LspConfig/1`); when it is degraded the language servers are
withheld, never configured in-process ("LSP configuration" below). Step 5m
adds `tests` (`loomworks.Tests/1` with `discover`, `run_cases`,
`prepare_debug`, `collect` and `result`, and `loomworks.view.Tests/1`); when
it is degraded the test explorer shows tests unavailable, never discovering
or running them in-process ("Tests" below). The describe is bounded
(about 3 s) and never blocks the editor; when it fails or times out the editor
uses `welcome.objects`. Between a lost connection and the reconnect the
editor's workspace is unloaded ("Unloaded on disconnect" below); the
reconnect's discovery and first reads end it. An interface that appears later (the root's
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

**Editor operations.** *(Step 5k, done: part 0 the spec; B1 and B2 the
daemon side, §19.15 "Editor scopes and configure", "Debug", "Build scope of a
launch", [API.md](../protocol/API.md) §12; C1 the calls, task runner and cancellation;
C2 run and debug through preparation and the debug adapters.)* In `daemon`
mode, while connected to a compatible daemon, the editor runs these
operations as **interface calls**, owning their tasks (§19.15 "The editor as
owner"):

- builds — of a profile (`Build/1.build { profile }`), of configuration units
  (`units`), serial (`jobs = 1`). *(Step 5o C2d.)* The status page names the
  profile and the units by its view rows' ids (`{ id }`, a unit row's
  `unit_id`), never by key; a row without an id offers no operation. Its
  cancel and task output of a row are the tasks whose meta names the row's
  ids ([API.md](../protocol/API.md) §4.2) — cancel only for a task the editor
  owns;
- *(step 5t)* the build of a non-device launch target (`Launch/1.build`; the
  editor's *Build default target*), as one owned task — its dependencies, its
  pre-build deploy and its own build never run in the editor; its progress
  entry follows the task's current step ([API.md](../protocol/API.md) §4.3). The
  artifact-conflict question is asked before the call, over the units it
  builds, and its answer sent as `force`;
- configures — of a profile or of units (`Build/1.configure`);
- module cleans — of a profile or of units (`Build/1.clean`), and the clean
  of a clean-and-build, followed by its build as a second call once the
  clean's task ended successfully;
- the preparation of run and debug launches of non-device targets
  (`Launch/1.prepare_run`, `Launch/1.prepare_debug`, both with `build_scope =
  "target"`; from step 5t with `force` as for a build, the progress entry
  following the current step): the editor then runs the returned `launch` in its task runner,
  or hands the returned `debug` to its debugger (its adapter-specific shape
  and the installed-adapter check, made before the call, stay in the editor,
  §8.9.6; the adapter checked is the one the daemon's mapping names,
  `DebugConfig/1.adapters`, while it is carried — never the editor's own
  mapping: while it is not carried, its read failed, or it does not name the
  language, nothing is checked before the call and the debugger checks the
  prepared adapter). A preparation that ends with
  `device = true` (a target found foreign by probing its artifact, spec
  §18.1) is **refused** *(step 6b-α; before it the run continued in the
  editor from the post-build deploy)*: the editor does not execute foreign
  targets (spec §18.11), so no program is started and nothing of the run
  continues in the editor. Its error notification names the target and the
  remedy, `<target> runs on a device: the editor does not execute foreign
  targets (spec §18.11); run it with lw run`. Runner devices (§18) stay out
  of the editor. A device target of spec §11 is launched through
  `Devices/1` ("Devices" below). The program is the editor's, never the daemon's; stopping a run or
  debug session stops it as in-process. While the preparation runs, a stop
  cancels its task (`Tasks/1.cancel`) and no program is started, and a
  second launch asks, as for a running session, before it replaces it.
  *(Step 5l.)* While the workspace is unloaded — the daemon reports it
  `unloaded`, or the connection is lost ("Unloaded on disconnect" below) —
  a run or debug launch is not offered and, when asked for, is refused with
  that status, never prepared in-process: its launch information comes
  only from the daemon;
- the debug adapters section reads and writes `DebugConfig/1` (`adapters`,
  `known_languages`, `set_adapter`) and re-reads it on `Workspace/1`
  `changed`; while it is not carried the section is unavailable and its
  writes fail, as any operation is refused ("Availability" below).

Test runs and discovery go through `Tests/1` (step 5m, "Tests" below);
device-target launches through `Launch/1.build` and `Devices/1` (step 5n,
"Devices" below). The editor runs no operation itself.

**Model writes.** *(Step 5o.)* In `daemon` mode the editor writes nothing
to the workspace's files and runs no deletion: every status-page action and
editor dialog that changes the model is a call to a command method of
§19.14, naming its entities by the ids of `view.Workspace/1` — for a
project's variable, deploy destination or `type_config` field, the
project's id and the entry's name. A dialog reads what it edits with
`Projects/1.declaration` when it opens; a confirmation (a deletion, a nuke,
trust, the removal of the working copy) shows the `confirm` lines and sends
back their `plan`. A confirmed deletion first cancels the editor's own tasks
whose meta names the confirmation's `unit_ids` (or, for a profile, the
profile row's id) — never matched by key or path ([API.md](../protocol/API.md)
§22); a confirmed nuke cancels every task the editor owns. A refused call (a stale id after a reload, a changed
plan, a held lock) is an error notification and changes nothing; the page
shows the views' next `update`. The editor never keeps an id across a
`header_changed` that reloaded the workspace. While a method's interface is
not carried the action is refused ("Availability"), never run in-process.
With no workspace loaded (its load failed, or a trust or schema refusal
unloaded it; from step 6b-α as `view.Header/1`'s `state` reports it) the
mode is the editor's setup selection; in `daemon` mode every action is
refused, nothing sent and nothing run — the nuke, trust and the removal of
the working copy name their command (`lw nuke`, `lw trust`, `lw trust
--discard`) *(until the editor can connect to a daemon for a root it has
not loaded)*. Creating a workspace (the status page's `N`, a new
`loomworks.json` where none is) is likewise refused in `daemon` mode, loaded
or not, nothing written: its error notification names `lw init` *(step
6b-α; [API.md](../protocol/API.md) §6 defers `Workspace/1.create` until a
server serves a root with no `loomworks.json`)*.
*(Status: every status-page action is a call. Its `Workspace/1`,
`Profiles/1` and `ConfigSets/1` actions are calls from step 5o part C2a,
its `Projects/1` actions from C2b (the removals, variable and
`type_config` edits and project add from its first half, the
configuration editor (C2b2-1) and the launch, deploy and path editors
(C2b2-2) from its second), the SDK section's `Sdks/1` actions and the
toolchain rescan from C2c-1, and its deletions and nuke — the project
row's removal and the project browser's among them — from C2c-2: a
confirmed `Maintenance/1` call is a task the editor owns, reported when
it ends; and the Profiles section's builds, configures, cleans, cancels,
task output, options and device choice name their rows by id from step 5o
C2d.)*

A confirmation the editor shows before an operation
(a clean's) is asked before the call (§19.15 "Confirmation"); so is the
artifact-conflict question of a build (§5.9) for the units whose artifacts
are known then (configured ones; in `daemon` mode as the view's unit rows
report them, `artifact_block`, never from the editor's model), its Yes sent
as `force` — a conflict found only after the routed build's own configure
ends the task as the CLI's routed build does (the refusal naming `--force`). Each call
carries the editor process's whole environment **at call time**, under the
rules of §19.15 "Environment" — what an in-process task of the editor
inherits.

**Availability.** *(Step 5s, done; before it the editor ran an operation it
could not carry in-process.)* The editor routes an operation only when it
can be carried; otherwise it refuses it. It is carried
while connected through interfaces to a compatible daemon that offers
`loomworks.Build/1` and `loomworks.Tasks/1` (its `cancel`: an operation the
editor could not cancel is not routed) and has not shown the method
missing on this connection:

- no connection (no host binary, a relay still starting, the daemon stopped,
  a daemon found incompatible — the editor never routes to one, including
  one with older schemas it only observes), or a feature degraded (its
  interface or method missing — an older daemon's `unknown_method`, or
  `invalid_args` for a parameter it lacks, means nothing ran): the operation
  is **not run**. It is refused at once with the observer's Runtime-line
  note as its message (e.g. `build: waiting for the workspace daemon
  (connecting)`, `operations: daemon offers no
  loomworks.Build/1.configure`); the action stays offered so the message is
  visible;
- `declined` (a foreign kit, trust, another environment while a build runs):
  the operation fails with the reason as one notification line;
- `refused`: the operation fails with the refusal's message, as the
  in-process operation would have refused it;
- the connection lost **after** `accepted`: the operation fails ("the
  workspace daemon disconnected") and is **never re-run in-process** (for a
  launch: no program is started), as for the CLI (§19.15 "Cancellation").
  An `internal` error from a call is handled as by the CLI (§19.20 "The CLI's
  calls"): the operation fails and is not re-run.

There is no in-process fallback and no opt-out; the editor never runs
workspace logic itself. *(Transition, until step 6b-β: the deprecated
`runtime.mode = "in-process"` editor of §19.1 runs every operation
in-process, never routing; the cross-process build-directory locks (§16.6)
serialize its operations with a daemon's.)*

**Public API.** *(Step 6b-α, plan; a breaking change of the plugin's Lua
API in `daemon` mode.)* In `daemon` mode the plugin's public functions answer
only from what the daemon gave the editor — its views, the `LspConfig/1`
state ("LSP configuration" below) and replies — never from a model (the
editor holds none, "End state"). A getter returns **plain tables**: copies
of the view rows that carry the facts, with their ids, which are what a
call's `{ id }` reference takes ([API.md](../protocol/API.md) §1.2); writing
to a returned table changes nothing. While the view a getter reads is not
held (not yet connected, disconnected, not offered) it returns `nil`:

- `lw.get_profiles()` — `view.Workspace/1`'s `profiles` records, by key;
  `lw.get_active_profile()` — the record whose `active` is true;
- `lw.get_projects()` — its `projects` records, by key;
  `lw.project_for_buf(bufnr)` — the buffer's `view.ProjectsIndex/1` record,
  as `lw.buf_project` (§19.13);
- `lw.get_config_sets()` — its `config_sets` records, by name;
  `lw.get_active_configuration_set()` — the record whose `active` is true;
  `lw.get_tool_entries()` — per configuration set name, the `profiles`
  records of that set;
- `lw.get_tools_by_type()` — per module type, the distinct `tools` rows
  (`{ module, key?, label }`) the `profiles` records select; the toolchains
  a module detects are `Toolchains/1.list`, a call;
- `lw.get_orphaned_configs()` — its `orphaned.configurations` records;
- `lw.get_lsp_options(server)` — that server's options in the held
  `LspConfig/1` state;
- `lw.get_workspace()` — always `nil`.

The pickers, build and launch functions act by calls, always on the active
profile row; a Profile argument is ignored:

- `lw.pick_profile()` lists the `profiles` records and sends
  `Profiles/1.set_active`. It offers no "None", because no call deactivates
  a profile.
- `lw.build_profile()` is `Build/1.build` of the active profile's id, an
  owned task as in "Editor operations". A failed reply that was not already
  notified is one warning: its message, else `build failed`.
- `lw.build_target()`, `lw.launch_target()` and `lw.debug_target()` act on
  the active profile's default target, which is the `Launch/1.targets`
  record marked `default`. They are its `Launch/1.build`, and the
  preparation of its run or debug (`Launch/1.prepare_run`,
  `Launch/1.prepare_debug`), as in "Editor operations". When the profile has
  no default target, the target picker opens first. Its choice is stored
  (below) and the action goes on with it. When the stored default no longer
  resolves (the row's `default_target_valid` is false), the editor first
  warns `target '<default_target>' no longer available` and then opens the
  picker.
- `lw.pick_target_action()` offers "Build" and "Switch target" on a valid
  default target (as the row reports it). Without one it opens the target
  picker.
- `lw.pick_target()` lists `Launch/1.targets`, in one call when it opens,
  with "None (clear target)" first. It sends the choice, or the removal of
  the stored choice, with `Profiles/1.set_default_target`
  ([API.md](../protocol/API.md) §9.6, §11).

**A default target is addressed by its profile alone.** A call on the
profile's default target sends `profile` but no `target`, `project` or
`kind`. The daemon then resolves the profile's own stored default target
(§16.17 "Launch target selection"), including its descriptor's
`working_dir` override. A target rebuilt from its project, name and kind
would lose that override. Any other target is addressed by its project's
id, its name and its kind. A device target is reached only as the default,
so it is always addressed by its profile.
The deploy editor's source targets are `view.Workspace/1`'s
`projects[].targets`, joined by project id, so a project in no profile
offers its targets too. A refused or uncarried call is an error
notification and changes nothing ("Availability").
`lw.compile_command_for_file(file)` and `:LoomworksCompileCommand` are
**refused** in `daemon` mode — `not available with the workspace daemon` —
and never read a compilation database or a model (BACKLOG "Per-file compile
command over the daemon"). *(Transition, until step 6b-β: in `in-process`
mode every function keeps its model objects and behaviour.)*

**LSP configuration.** *(Step 5l, done: part 0 the spec; A the
host-neutral builder of the state, in-process only; B the daemon side,
[API.md](../protocol/API.md) §13; C the editor side.)* In `daemon` mode what the
editor's language servers are configured with — each project's
`lsp_configs` entries with their `db_state` (§9.1), the working copy's
per-server options (§2, `user.json` `lsp`), and whether the active profile's
owned databases are ready (§9.7) — comes **only** from the workspace daemon,
as `LspConfig/1.get` answers it ([API.md](../protocol/API.md) §13). There is no in-process fallback:
the editor never builds that state itself — it does not call `lsp_configs`,
derive a `db_state`, read options from its own model, generate or scan an
owned database, or map a buffer to a project other than by `lw.buf_project`
— and when the daemon cannot give the state, the servers wait or are
withheld (below), never configured from anything else. The daemon's state is
**in use** while the editor is connected through interfaces to a compatible
daemon that offers `loomworks.LspConfig/1` and the last read answered with
state `loaded`. The servers stay the editor's: starting and stopping them,
the integrations (found on the editor's runtime path, §9.2) with their `cmd`
and `root_dir` factories and `withhold_reason` (with its absent-database
check), the expansion of variables in a server binary, the §9.7 hold, the
per-buffer status (§9.8) and the restart throttle (§9.6). `get` carries the
editor process's whole environment at call time (§19.15 "Environment"), so
an entry's server binary resolves as the editor would run it.

- **Reads.** The state is cached per connection and read again on
  `LspConfig/1` `changed`, on `Workspace/1` `changed` and on reconnect; the
  first read is made once the interface is discovered. A cached state is
  dropped when its connection is lost.
- **Readiness.** While the daemon's state is in use, the §9.7 hold is
  released on the state's `ready`; the editor model's own loading,
  readiness or failure takes no part in the hold or in any LSP decision.
  While the state is `loaded` but not `ready`, buffers under the root stay
  held, bounded by the §9.7 safety timeout, at which they are resolved
  against the daemon's state (a buffer whose entry has no usable database is
  withheld, never started).
- **Waiting.** While the editor waits for the daemon — the relay starting or
  connecting, the describe or the first `get` not answered, the state
  `unloaded` (the daemon has not loaded the workspace yet — "Loaded on
  attach" below), or the
  workspace unloaded because the connection was lost ("Unloaded on
  disconnect" below) — buffers under the root stay
  **held** (§9.8 status `held`) with **no timeout**: the §9.7 safety timeout
  does not apply, and nothing is resolved against another source. The
  Runtime line says so (`lsp configuration: waiting for the workspace daemon
  — language servers held`, spec/ui.md §1.1). The hold ends when a read
  answers `loaded`, as under "Readiness".
- **Unavailable.** When the daemon cannot give the state — no host binary
  ("Host binary" below; the editor's other operations then run as that
  paragraph says, its language servers do not), a daemon found incompatible,
  `loomworks.LspConfig/1` missing or offered only at another version, a
  `get` that is declined or fails, or a state of `error` or `refused` (the
  daemon's load of the workspace failed or was refused) — buffers under the
  root are **withheld** (§9.8: `withheld_error` for a state `error` or
  `refused`, `withheld_daemon` otherwise), and the reason is the Runtime
  line's note in the warning highlight (e.g. `lsp configuration: daemon
  offers no loomworks.LspConfig/1 — language servers withheld`, `lsp
  configuration: no lw host binary — language servers withheld`). A
  declined or failed read is retried on the next `changed`, `Workspace/1`
  `changed` or reconnect; a state `loaded` re-evaluates the withheld buffers.
- **Running clients.** A lost connection stops every client of a server
  loomworks controls (§9.4 default path) under the root, through the
  managed-stop path (§9.6, so it is neither suppressed nor counted against
  the restart throttle), and its buffers become `held` ("Unloaded on
  disconnect" below); they start again only when the daemon, after the
  reconnect, reports the workspace `loaded` and their entry usable and
  `ready` (§9.7). Otherwise only a state in use changes a running client:
  when its entry becomes withheld it is stopped the same way (§9.8
  "Re-evaluation"). Waiting while connected, or an unavailable
  configuration, starts no client and stops none — a client started from an
  earlier state keeps running, and its buffers keep status `ok`, until a
  state in use says otherwise, which then restarts a client only when its
  resolved binary or database directory differs.
- **Owned databases.** Only the daemon generates the owned LSP databases
  (§8.4 `refresh_lsp_database`): the editor's model never does — not at its
  startup scan, not after a task, not on a watched path — whether or not the
  state is in use. A database the daemon (re)writes reaches the editor as a
  raised `db_rev` on its entry ([API.md](../protocol/API.md) §13), on which the editor runs the
  owned-database completion handling of §9.8 for that entry.
- **Re-evaluation.** When a read gives entries or options that differ from
  the ones in use, or the state starts or stops being in use, the editor
  re-evaluates as for an active-set change (§9.8 "Re-evaluation"): a
  withheld or held buffer whose entry became usable is started, a client
  whose entry became withheld is stopped through the managed-stop path, and
  a changed but still usable entry restarts through its integration.
  Changed options are applied as an option change (clangd: its spec §12.2).
- **Options.** A per-server option the editor sets (the status page's LSP
  section) is written **only** by `LspConfig/1.set_option`; the editor
  never writes `user.json` `lsp` itself. When the interface is not carried,
  or the call is refused, fails, or gets no answer before the connection is
  lost, the write is an error shown with its message (a `refused` one with
  the daemon's) and nothing changes; the editor applies an option only from
  the state it reads back, not from its own write.
- **Buffer → project.** The LSP layer maps a buffer to its project only by
  `lw.buf_project` (§19.13, separator-bounded), matching the record to the
  state's project by key; `lw.project_for_buf` stays public API.

*(Transition, until step 6b-β.)* In `in-process` mode the editor still builds
the state from its own model with the same builder (§9.2), generates the
owned databases and writes options in-process, under §9.7 as before 5l; the
buffer → project rule above applies there too. That path is the
`in-process` mode's, removed with the in-process editor (§19.19 6b-β); it is
never used in `daemon` mode.

**Tests.** *(Step 5m, done: part 0 the spec; A the host-neutral builder of
the view and loomtest's adapter-executed runs, in-process only; B1 the
daemon's discovery and view, B2 its runs, debug preparation and results,
[API.md](../protocol/API.md) §10, §14.3; C1 the editor's read path, C2 its
runs and debug.)* In `daemon` mode the editor computes nothing about tests:
it does not discover them, build or run a test program, parse a test
program's output or results file, match a test to a build target, or keep
results of its own. The test tree, its states and the last results come
**only** from `view.Tests/1` (with `Tests/1` `results` for a run's
progress); discovery, runs and debug preparations are `Tests/1` calls. The
test explorer, its gutter signs and inline marks (LOOMTEST.md) are the
editor's — rendering, navigation, the cursor's test, the output window.

- **Discovery.** `Tests/1.discover` is a task ([API.md](../protocol/API.md) §10.2), owned by the editor
  like an operation's ("Tasks in the task runner" above: one overseer row,
  cancellable, its one progress entry), carrying the editor's whole
  environment at call time (§19.15 "Environment"). The editor sends it only
  when the view needs it: when the explorer is opened or the adapter first
  asked for the tree while the view is `stale`, on the explorer's refresh
  (`force`), and when the view turns `stale` while the explorer is open —
  never on its own otherwise, and not while the view's `discovering` names a
  running discovery (another client's included), whose `update` it waits
  for.
- **Runs.** Running a test, a suite, a target, a file's tests or all of them
  is one `Tests/1.run_cases` call (`select` the nodes' ids; run-all sends
  none; "no build" sends `no_build`), owned by the editor and shown as one
  overseer row whose output is the task's frames. The pre-run build is part
  of that task, under its locks (§19.15 "Tests"): the editor builds nothing
  for a test run and the adapter's `ensure_built` is not used. While it runs
  the explorer, signs and inline marks follow `Tests/1` `results` (another
  client's runs too); its end is the view's `update`. Stopping the overseer
  row cancels the task (`Tasks/1.cancel`). Concurrent runs queue behind the
  build-directory locks (§19.15 "Tests").
- **Debug.** Debugging a test is `Tests/1.prepare_debug { select }` (`select` a
  single `TestNodeRef` object, not an array; a task as
  `Launch/1.prepare_debug` is, building what a run of the node would);
  the editor hands the returned `debug` to its debugger as for a launch
  (the adapter-specific shape in the editor), and when the session ends it
  calls `Tests/1.collect { prepared }` so the daemon reads the results the
  program wrote and updates the view. The program is the editor's, never the
  daemon's. No language or adapter is assumed by the editor: they come with
  the `debug` spec, so the installed-adapter check (§8.9.6) is made after
  the task's `done` and before `debug.run()`, not before the call as for a
  launch. When the adapter is not installed the editor shows the install
  hint, starts no session and calls `Tests/1.collect { prepared }` at once,
  which drops the token and its results file (the program never ran, so it
  records nothing); a `done` without `debug` carries no token to drop.
- **Output.** The output and error locations of a node (the explorer's
  output window, the first-error jump, the inline marks and diagnostics of
  failed nodes) are read with `Tests/1.result { id }` when shown.
- **Unavailable or unloaded.** While the workspace is unloaded (the daemon
  reports it `unloaded`, or the connection is lost — "Unloaded on
  disconnect" below, the view cleared then), while it is `error` or
  `refused`, and while the feature is degraded (no host binary, an
  incompatible daemon, `loomworks.Tests/1` or `loomworks.view.Tests/1`
  missing or at another version, a daemon that offers no
  `loomworks.Tasks/1` (needed to own a discovery)), the explorer's header
  shows that status (e.g. `tests: waiting for the workspace daemon`,
  `tests: daemon offers no loomworks.view.Tests/1`), its tree is empty, and
  discovery, runs and debug are refused with that status as one notification
  line — **never** done in-process. Gutter signs and inline marks are cleared with the tree. On
  reconnect the subscription's `initial` restores the tree and the daemon's
  last results; a discovery, run or preparation the editor owned past
  `accepted` fails with the connection ("Editor operations" above) and is
  never re-run.
- **Neotest.** The neotest adapter (§8.9.4) is **not available** in `daemon`
  mode in this step: it discovers nothing and, the first time neotest asks
  it for anything in a session, shows one notification (`loomworks: neotest
  is not available with the workspace daemon — use the loomtest explorer`).
  A daemon-mode neotest (positions from the view, runs through a CLI relay)
  is later (§19.19 5m part D).

*(Transition, until step 6b-β.)* In `in-process` mode the editor keeps its
in-process discovery, its RunSpec runs with loomtest's own streaming and
results parsing, its `ensure_built` and the neotest adapter, unchanged; that
path is never used in `daemon` mode.

**Devices.** *(Step 5n, done: part 0 the spec; B2 the daemon side,
[API.md](../protocol/API.md) §9.4, §11, §15 — implemented; C2 the editor's use — implemented;
B3 the device log stream, [API.md](../protocol/API.md) §9.5 — implemented; C3 its editor use — implemented.)*
In `daemon` mode the editor neither lists nor probes devices, nor installs
or launches on them. The device list comes only from `Devices/1.list` and
its `changed` signal. A scan is a `Devices/1.scan` task carrying the
editor's environment. A device target's launch is a `Launch/1.build` call,
then `Devices/1.install` and `Devices/1.launch`, each owned by the editor
like an operation's task. Choosing a profile's device is
`Profiles/1.set_device`. Device-target launches are no longer an exception
in "Editor operations"; while the daemon cannot carry them they are refused
like any operation ("Availability"). Devices are runtime state. A reload of
the workspace keeps the device list and its ids, and doesn't cancel device
installs or launches that are running. That includes a reload caused by a
scan from a client with a different environment. An install takes the build
directory's lock and then the device's. While it waits for the device lock,
the build directory stays locked, so a build of that directory fails at once
in the meantime. A launch and a stop take only the device lock. A launched
program's log is a `Launch/1.device_log` task of the client that launched
it, which holds the device lock only while it clears the device's log; its
stream takes no lock. The editor starts it when the launch is done and shows
its records in the device-log view, through a subscription to that task's
`log` signal. Closing the view, or stopping the run, cancels the task and
drops the subscription.
Opening the view again while the run is active starts a new one. When the
task ends, the view keeps what it showed and its last line says the stream
ended.

**Tasks in the task runner.** Every daemon task the editor knows becomes
**one** task in the editor's task runner (overseer, §12) — one per daemon
task, not one per step: a profile build is one entry whose output carries the
`==> [build] <project>` lines, where in-process it is one entry per project;
the units' states come from `meta.units` (Running state below). *(Step 5t:)*
a task carrying steps ([API.md](../protocol/API.md) §4.3) keeps its one entry, which
follows the task's current step.

- An **editor-owned** task is a task-runner task whose start is the call,
  whose stop is `Tasks/1.cancel` (§19.15 "The editor as owner"), whose
  restart sends the call again, and whose output is the task's frames written
  to a terminal buffer, so colours and the task runner's own output actions
  (opening the output in the quickfix list) work as for a local task.
  As for Editor operations, a restart that is declined, degraded or cannot
  be carried fails the task-runner task with the reason and never runs
  in-process (the overseer task follows exactly one daemon task). A degraded restart
  still sets the Runtime-line note, as any degraded call does. The task of
  a launch's preparation (`prepare_run`, `prepare_debug`) is not sent
  again: its program is started by the editor's launch after the call,
  which a restart of the task alone would not start, so its restart fails
  the task-runner task with the reason (start the launch again from the
  editor). A device target's `Devices/1.launch` task is not restartable
  either: restarting it would start a second program on the device, which
  the editor never learns the task of and so cannot stop. A stop, or
  another restart, before a restart's call is accepted cancels the task that
  call starts; it is never shown as a task of its own. A task that ends with
  exit 0 after a cancel is a success.
- An **observed** task (another client's, `meta.origin`) is listed
  read-only, its origin marker in its name (e.g. `[lw] build dev`); stop and
  restart only say `started by lw (cli) — cancel it there`. Its output
  starts when the editor joined (Joining late below).

The editor ignores `role`: it appends each line's text, the command lines of
`verbose` included, as it appends every `line`.

No diagnostics are parsed from a task's output by loomworks, for daemon tasks
as for local ones; the quickfix list is the task runner's own action. When
the task runner cannot host such tasks (its extension point unavailable), the
editor keeps them out of its list and shows them as remote tasks only (UI
below), with a Runtime-line note. An editor-owned task has **one** progress
entry — the remote-task entry of UI below, with no origin marker — and the
editor's own progress wrapper is not shown for a routed operation; a launch's
or debug session's final phase (running, debugging) keeps its own entry.

**Step 4: the observer.** In `daemon` mode (§19.1), each
workspace the editor loads gets an **observer**. It watches the task streams
and model changes of operations started elsewhere (a `lw build` in a
terminal). It runs none of the editor's own operations; where those run is
"Editor operations" and "Availability" above. In `in-process` mode nothing below happens.

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
    older or newer than the plugin's, a missing root interface, or an `lw`
    older than §16.41 — `version --json` succeeds but prints no descriptor:
    it predates the plugin's schemas, and a release before the daemon cannot
    run one) — a
    search-path `lw` is skipped with
    a status note naming the problems ("too old/incompatible: …") and the
    search goes on to the managed `lw`; an explicit binary is never
    replaced (rule 1), the verdict is only noted;
  - **unknown** (`version --json` exits non-zero — e.g. a host with no
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
  `lua/loomworks/provision/pinned.lua`, `{ version, assets = { [<asset>]
  = <sha256> } }` with one hash per published host asset (`lw-linux-x86_64`,
  `lw-macos-arm64`, `lw-windows-x86_64.exe`; the plugin keeps its own copy of
  that table) and one for the release bundle `loomworks-lua-<version>.zip`. A
  pin without the bundle's hash wants no managed `lw`. It is never edited by hand: `scripts/release/pin.sh` writes it
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
  and equals the draft's signed hash for every host asset and the bundle, the
  signature verifies, every host binary and the bundle of the draft are
  present and match `SHA256SUMS`, and the
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
  — asynchronously, the editor is degraded meanwhile and the Runtime note
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
  why (running degraded); it is not retried until `:LoomworksDaemon
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
  renamed over it.

  **The managed bundle.** A release host carries no system Lua (§16.22), so
  the managed `lw` is a pair: the host binary above and the bundle
  `loomworks-lua-<version>.zip` of the same release, hashed by the same pin or
  channel result. The bundle lives at
  `<editor data>/loomworks/bundle/<sha256>/lua-<version>/`, `<sha256>` being
  the zip's SHA-256: exactly the zip's entries, written once, never modified.
  Every process the editor starts from the managed binary (relay, the daemon
  it launches, the channel query, a retirement's relaunch) gets
  `LOOMWORKS_INSTALL_DIR=<editor data>/loomworks/bundle/<sha256>`, so `lw`
  runs that bundle as a release source (§16.22) and still follows a
  repository pin (§16.23); never `LOOMWORKS_LUA` (a development source
  bypasses the pin). `lw` may write there what its install folder holds
  besides bundles (`release-notes-seen`, the pin redirect's `pinned/`); the
  plugin never runs `lw self-update` with it. A search-path or explicit `lw`
  gets no install-folder override.

  When the managed `lw` is wanted and its bundle slot is absent, the zip is
  downloaded with the binary's source, transfer bounds and `binary.download`
  switch into `<sha256>.<pid>.<n>.dl` in `loomworks/bundle/`, and its SHA-256
  must equal the wanted one. The plugin reads it itself (no external tool).
  Nothing is installed unless every entry:
  - is a regular file or directory (no link, no other type) under
    `loomworks/`;
  - has a name of `/`-separated segments, none empty, `.` or `..`, with no
    leading `/`, no `\`, `:` or NUL;
  - has a name no other entry repeats case-insensitively;
  - matches its CRC-32.

  Entries are written as newly created regular files (never through an
  existing file or link) into
  `loomworks/bundle/.stage-<sha256>.<pid>.<n>/lua-<version>/`, created by an
  exclusive mkdir. The staging directory is then renamed to
  `loomworks/bundle/<sha256>` (on Windows retried briefly). The rename never
  replaces a non-empty directory: a slot another editor installed meanwhile
  is used. Requests for one hash share one provisioning. A failure installs
  nothing and is one note (running degraded), not retried until
  `:LoomworksDaemon connect`. The temporary file is removed, and the editor
  removes its own staging directory: only that exact path, a real directory
  under `loomworks/bundle/`, with links inside unlinked, never followed.

  `loomworks/bundle/` and its slots are created as, and must be, real
  directories. A slot is present only when `<sha256>` and `lua-<version>` are
  real directories (lstat) and `lua-<version>/loomworks/cli.lua` is a regular
  file. It is then used by presence: it is only ever populated by the rename
  after verification, as for `lw`'s pinned bundles (§16.24). Any other state
  at that path is never used, never repaired or removed automatically, and
  makes the managed source absent with one note naming it.

  The source is `<base>/<asset>` for a release-source override (the
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
  Pruning of managed binaries and bundles is paused (samienne/loomworks#101):
  the editor removes no slot in `loomworks/lw/` or `loomworks/bundle/`, and
  nothing another process left there; it removes only its own temporary file
  and staging directory of a failed attempt. Slot directory mtimes (binary and
  bundle slots) still record last use for that future pruning. A search-path or explicit `lw` is probed before
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
     The output must name a valid release version, this host's asset and
     `loomworks-lua-<version>.zip`, each with a 64-hex hash, and carry the release's descriptor; that descriptor must
     pass the interface check of "Plugin pin", with the pre-launch probe's
     schema rule (schemas **equal** to the plugin's: the managed `lw` is what
     the search falls through to, and a daemon with older schemas would be
     weighed for a retirement).
  3. A result that passes and names a version newer than the current wanted
     one (§16.29 ordering: a pre-release ranks below its release) is
     **accepted**: it becomes the wanted binary and bundle, both provisioned as
     above, each hash-checked against the query's hash. It is recorded as
     accepted only once both succeeded; a failed download is one note and
     the current wanted binary stays. A running daemon is not
     switched while it is busy: its code identity now differs from the
     wanted binary's, so the editor retires it once it is idle (§19.9
     "Editor retirement") and the next launch uses the new binary; the
     Runtime note says so.
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
  editor sends `retire` (never `stop`) to an incompatible daemon, or to a
  compatible one whose code identity differs from the relay's
  (`welcome.relay`) (§19.9 "Editor retirement"), only when all of these hold:
  - the daemon is idle (no busy client, §19.9 "Busy") — the editor's own
    connection included: from step 5k a task the editor owns makes it busy,
    so the editor never retires a daemon under its own running tasks (and it
    routes nothing to a daemon it found incompatible, "Editor operations"
    above);
  - its schemas are not newer than the editor's;
  - the binary the editor selected passed the interface check (the probe's
    *compatible* verdict, or the managed `lw`);
  - the binary that would start in its place has another code
    identity (`lw_version`, §19.9) than the daemon: for a compatible
    daemon the relay's (`welcome.relay`, which must be present), for
    an incompatible one the selected binary's;
  - the editor has not already retired a daemon of that identity for this
    workspace in this editor session.

  Then the "Retiring" path below relaunches once. A busy incompatible daemon
  is a note ("incompatible daemon is busy; retiring when idle") and is
  re-checked through `status` about every 30 s. When the once-per-version
  rule stops the retirement of an incompatible daemon — the successor runs
  the same version again, typically because a repository pin redirects to
  it — the note says so (the daemon runs lw <v> again, likely a repository
  pin; update the pin or the plugin); when that earlier retirement failed (below), the note says
  instead that retiring a daemon of that version failed earlier this
  session, and it is not tried again. A compatible daemon stays observed
  throughout, with no note: busy, it is re-checked the same way and retired
  once idle; declined, it stays observed. Only a failed retirement of it is
  noted on the Runtime line.

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

  **Install location.** Everything the plugin installs (host binaries in
  `loomworks/lw/`, release bundles in `loomworks/bundle/`, and what a managed
  `lw` downloads for itself, the pin redirect's binaries and bundles, through
  its install-folder override `LOOMWORKS_INSTALL_DIR`, which is its bundle
  slot, §16.22) stays under the
  editor's data directory (`<editor data>/loomworks/`) — except the bundle
  copy a pinned release older than the install folder provisions for itself,
  which lands in `lw`'s per-user data directory (§16.22). The plugin never installs a system-wide `lw`
  and never writes configuration into the user's home. Shared runtime state
  stays where `lw` keeps it, for every `lw` on the machine: daemon sockets and
  identity, the trust store (§17.2), daemon logs. The plugin reads `lw`'s
  per-user configuration (its settings, §19.1) and writes it only on an
  explicit user action.

  With none, the status page shows one inline note naming each source and
  why it gave nothing (no host binary: running degraded); while the
  observer launches, its note names the binary and its source.
  `:LoomworksDaemon status` and `:checkhealth loomworks` list every source
  with its verdict. The editor never launches a daemon from its own plugin
  source unless `binary.source` asks for it, and runs no loopback runtime
  until the thin-client part of §19.19 step 5 (the CLI's attached runs of
  step 5e do not include the editor). Until step 5i PR G1 it still watches
  for a daemon another client starts and observes that one. From PR G1 it
  does not: the editor follows daemons only through relays, which need a
  host binary, so with none it spawns no relay, runs degraded, and does
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
  `role = "observer"` — also from step 5k, when it owns tasks: an observer
  may start and own operations (§19.15 "The editor as owner"); there is no
  separate role. It observes a daemon whose transport range overlaps
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
- **Loaded on attach.** *(Step 5l.)* When an editor connects (`role =
  "observer"`), the daemon, after its `welcome`, starts loading the
  workspace unless it is loaded or a load is under way — as a `snapshot`
  loads it, in the daemon's own environment and without waiting for tool
  detection — so an editor-only session does not stay `unloaded`. A
  connection without that role (the CLI) never starts a load, and
  `LspConfig/1.get` still never loads. Because this load uses the daemon's
  own environment, a later operation from a client whose environment
  differs reloads the workspace first (§19.15).
- **Unloaded on disconnect.** *(Step 5l.)* When a connection the editor
  held is lost, for any reason (the daemon stopped, crashed, retired or
  dropped this client, the relay ended), the editor's workspace is
  **unloaded** in `daemon` mode until a reconnect's daemon reports it
  `loaded` again — as if the daemon had answered `unloaded`: nothing of the
  daemon's runs for it. Its remote tasks end ("Tasks" below), an operation
  past `accepted` fails ("Editor operations" above), and the controlled
  language servers under the root are stopped and their buffers held
  ("LSP configuration" above); the tests view is cleared and the explorer
  shows the status ("Tests" above). Programs the editor launched (in its task
  runner) and debug sessions are not stopped. The Runtime line says so in the warning
  highlight (`the workspace daemon disconnected — workspace unloaded,
  waiting for it`, spec/ui.md §1.1) until the daemon reports `loaded`. A
  workspace swap or shutdown is not a lost connection ("Teardown" below).
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
    from that moment; a task already ended is never shown. `status.tasks`
    carries no steps (frozen, §19.15): when it adopted a task and is
    subscribed to `/tasks`, the observer reads `Tasks/1.list` once and adopts
    the steps and current states it gives ([API.md](../protocol/API.md) §4.3); later
    `step` signals are deltas on top of them. `/tasks` signals that arrive
    before the subscribe reply are held, then applied only past its `seq`
    baseline (§19.12).
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
    it, from `meta.origin` (§19.15). *(From step 5k:)* it is also listed
    read-only in the task runner's task list, and a task the editor itself
    started through a call is shown the same way without an origin marker,
    cancelled and restarted from the editor ("Tasks in the task runner"
    above).
- **Teardown.** Unloading or swapping the workspace stops its observer: the
  timers stop, the connection closes, remote tasks are cleared. The daemon
  keeps running (§19.11); from step 5k the close cancels the tasks the
  editor owns (§19.15 "The editor as owner"), and their operations end as
  failed in the editor. *(From step 5i PR G1 the connection closes by
  closing the relay's standard input, a waiting relay is ended the same way,
  never by a process-tree kill: "The relay process" under "Through the
  relay" above.)*
- **Quiet degradation.** Every problem is the observer's one current note,
  shown on the status page's Runtime line, never a notification or a repeated
  message.

A version mismatch the editor cannot repair by restarting (its plugin code and
the resolved binary differ in protocol or schemas) is shown inline. The editor
runs degraded. The note is never silent: it stays on the Runtime
line (warning highlight) for as long as the mismatch lasts, naming both sides'
protocol (or schema) and versions, the binary's path when known (the
daemon's handle `exe`, §19.6, whoever started it; an older daemon's handle may
not name one), and the remedy (update
the plugin, or pin or install a matching lw), e.g. `Runtime:   daemon
(default) — lw v0.1.44 (protocol 7) does not match this plugin (protocol 6):
update the plugin or the pin — running degraded`. *(Step 5g.3.)*
From protocol 11 this whole-daemon note applies only to a transport mismatch;
a missing interface version is the per-feature note of "Interface client".

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
