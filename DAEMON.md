# loomworks daemon — design rationale and transition plan

> **STATUS: target design for review; implemented in steps.** This file is the
> *why* and the *plan*. The normative contract is
> [`spec/core/daemon.md`](spec/core/daemon.md) §19, which marks every part as
> *master*, *#88* (the experimental branch, draft PR #88), *re-cut* or *future*.
> Nothing in this document describes behaviour master has unless §19 says so.
>
> Related: [`ARCHITECTURE.md`](ARCHITECTURE.md),
> [`spec/core/headless.md`](spec/core/headless.md) (§16),
> [`spec/core/three-file-model.md`](spec/core/three-file-model.md) §2.7
> (concurrent writers).

---

## 1. Why

Today every host **is** the workspace: the editor and each `lw` invocation load
the model, write `.nvim/` files and run operations themselves, coordinating only
through the files, per-build-directory locks (§16.6), device locks (§18.7) and
the save guard (§2.7). That works, and it is safe for single-file writes, but:

- **Every `lw` call cold-starts** the workspace (read, remerge, detect tools) —
  noticeable in agent and CI loops.
- **The editor learns of CLI changes by polling** (~2 s) and cannot show a
  CLI-started build live.
- **Multi-file operations are not atomic across processes.** Publish writes
  `loomworks.json` then `loomworks.user.json`; a rename touches the working copy
  and the cache; nuke removes build trees and the cache. Two processes can
  interleave them, and a crash between the writes leaves a mix.
- **Module logic is editor-coupled** although nearly all of it is headless.

A single long-lived runtime per workspace removes the cold start, gives every
client a live shared view, and makes the runtime the one place that orders
operations.

## 2. Decisions

| # | Decision | Reason |
|--|--|--|
| D1 | **One daemon per workspace; essentially every operation goes through it; `lw` and the plugin are thin clients.** | One owner of the model and files orders all operations; clients stay simple. |
| D2 | **The CLI binary is the daemon** (`lw daemon run`); same executable as client. | Distribution, pinning, signatures and self-update are already solved for `lw` (§16.21–§16.32); no second artifact to ship or version. |
| D3 | **Default: `lw <cmd>` finds or launches (detached) the workspace daemon, sends the request, streams the result, exits, leaves the daemon running.** | Cold start paid once; nothing for the user to manage. |
| D4 | **`--no-daemon` runs the daemon code in the client process over a loopback transport** — same code, same protocol, no pipe, nothing left running. Auto under `CI=true`, after a failed background launch, or via `LOOMWORKS_NO_DAEMON=1` / setting. | Replaces the separate in-process implementation: **one** implementation of every operation, two transports. CI and sandboxes need no background process. |
| D5 | **One runtime per workspace in either mode.** `--no-daemon` takes the same runtime lock; uses a running daemon if there is one; waits briefly then fails "workspace busy" if another attached run holds it. | Never a second writer. |
| D6 | **Lifetime:** alive while any client is attached (editor keepalive), else exits after an idle timeout (default 1 h, configurable), or when the workspace root disappears. `lw daemon status|stop|restart`; a passive Runtime row in `lw status`. Handle records host and pid. | 1 h makes "mostly warm" the common case; shared drives need the host to avoid stopping a stranger's daemon. |
| D7 | **Version handshake:** protocol + lw version + schema versions. Idle mismatched daemon → restarted; busy → the client runs this command without it and the daemon retires when idle. | Same binary, so after `lw self-update` or a pin change a newer client meets an older daemon; never kill one serving others. |
| D8 | **Editor:** launches `lw daemon run` from the `lw` it resolves (broker: `LOOMWORKS_LW` → repo pin → PATH → provisioned); with no `lw`, runs the daemon code inside nvim over loopback. | Same runtime for editor and CLI; the plugin keeps working without a binary. |
| D9 | **Staged transition, locks first** (§5). Until every operation has moved, conflicting operations either fail or succeed — never an unknown state. | The in-process path, older versions and the daemon will coexist for months. |

The architecture choices of the earlier design are **kept**: daemon-authoritative
model with a client projection built by the same deserializer (§19.12);
session-local opaque ids for rename-stable wire identity (§19.11);
broadcast-everything coarse invalidation with seq + session generation; a
separate task stream with coalescing and bounded output (§19.14); three consumer
strategies (header / view-scoped / transient); FIFO commands whose effect returns
as a broadcast (§19.13); Lua for the daemon, with the protocol keeping a later
core rewrite possible.

### Superseded decisions

| Earlier decision (DAEMON.md on #88) | Superseded by | Why |
|--|--|--|
| **In-process is the PERMANENT default and fallback**; the daemon is an opt-in acceleration layer, never a hard dependency. | D1–D4: daemon is the end-state default; the fallback is the *same code* attached over loopback. | Two implementations of every operation means permanent parity debt, a fallback path that rots because nobody runs it, and two kinds of writer that can never be fully serialized. The robustness the fallback bought (CI, sandboxes, no binary) is kept by attached mode, which needs no background process. |
| Wire protocol versioned as a **compatibility range** `min_supported..current` (independently shipped sides). | D7: exact match for the CLI (same binary); protocol + schema match for the editor; a frozen control subset. | Client and daemon are one binary, so "compatible older daemon" only defers the restart; a range invites skew bugs. The frozen subset (auth, status, stop, retire) keeps any two versions able to talk long enough to fix the mismatch. |
| The daemon lock is the **write-authority token**; a client writes files only after taking it. | D5 + operation locks (§19.3): the runtime lock names the one runtime; per-operation locks + journal protect files. | During the transition the in-process path must write while a daemon runs; older versions never take the lock; a version-bypass run must be safe. Per-operation locks protect all of them; a lifetime lock protects none of them. |
| Idle timeout ~10 min. | D6: default 1 h, configurable. | Keep the daemon warm across a normal working session. |
| Separate `daemon` release channel / long-lived branch. | Opt-in `runtime-mode daemon` on master, step by step. | Each step is small and lock-safe on its own; a parallel line drifts (#88 already needed a full replay). |
| Broker may fall through to "bundled source, in-process". | D8: no binary → loopback inside nvim. | Same code either way; only the transport differs. |

## 3. Shape of the end state

```
   lw build ─┐                         ┌─ nvim plugin (projection, LSP/DAP/UI)
             │  pipe, mutual HMAC auth │
             ▼                         ▼
        ┌──────────── lw daemon run (one per workspace) ────────────┐
        │ model · .nvim files · operations · locks · task stream    │
        └───────────────────────────────────────────────────────────┘

   lw --no-daemon build:  [ client ⇄ loopback ⇄ same daemon code ]  in one process
```

The runtime lock (§19.2) makes "one per workspace" true in both modes; the
operation locks (§19.3) make every operation all-or-nothing whoever runs it.

## 4. Why operation locks come first

The transition has, at the same time: the editor and CLI on the in-process
path, a daemon running some operations, older pinned versions, and (later)
version-bypass runs. No single "who is the writer" token can cover all of them —
older versions will never honour it. What can cover them is making **each
operation** safe against every other operation:

- **All locks up front, fail-fast**, in one global order R → O → B → D → F
  (runtime, workspace operation, build directories, devices, file-save locks),
  canonical order within a class. Ordered acquisition makes deadlock impossible;
  up-front acquisition means a refused operation has changed nothing.
- **A workspace operation lock** for operations that touch more than one file or
  delete a tree (publish, import, pull, cache-propagating renames, deletions,
  reset, nuke, trust --discard). Single-file mutations stay on the existing
  stale-save guard, which already makes the O holder's final check fail if they
  slipped in.
- **`lw nuke` takes the build locks** of everything it removes — today it can
  delete a tree a build is writing.
- **Journalled multi-file commits** (§19.4): stage all files, write a journal
  (the commit point), rename in a fixed order, drop the journal. A crash before
  the journal leaves the old state; after it, any reader rolls forward to the
  new state; an unrecoverable journal refuses the workspace with a named remedy.
  Build-tree removal keeps the existing "mark unknown, delete, then forget" rule.

Because the daemon takes exactly these locks, routing an operation to it later
changes *where* it runs, not *what it is safe against*. The locks stay after the
transition: they are what makes version-bypass runs and older versions safe.

## 5. Transition plan

| Step | Content | Exit criteria |
|--|--|--|
| **1. Operation locks** | §19.3/§19.4 on the in-process path: `loomworks.op.lock`, lock-order audit (incl. device run vs build locks), nuke takes build locks, journal + recovery, `lw unlock` clears O / journal. | Concurrency tests: publish ∥ rename, nuke ∥ build, import ∥ publish, crash injected at every commit point → old or new, never mixed. |
| **2. Lifetime** | Server + mutual HMAC auth (§19.7), Windows DACL, launch recipe (§19.9), lifetime rules (§19.10), version handshake (§19.8), `lw daemon status|stop|restart`, Runtime row, `--no-daemon` (= in-process for now). Opt-in `runtime-mode daemon`: every workspace command keeps the daemon running though it only answers `ping`/`status`. | Weeks of daily use with the daemon resident: no stray processes, no stuck locks, clean restart after self-update, Windows job-object kills recover. |
| **3. First operation: `lw build`** | Re-cut #88's delegation (parity-tested there) onto step 1–2 foundations; all build forms. | Build parity test; delegated builds in the LumeEditor peer session. |
| **4. Editor connects** | Plugin resolves `lw`, launches/connects, keepalive, observes task streams and model changes; still runs its own operations in-process. | CLI build visible live in the status page; editor reload/exit never orphans or kills a busy daemon. |
| **5. Remaining operations** | One at a time (configure/clean/reset, run/test, profile/project mutations, publish/import/pull, devices), each with a parity test; then the loopback transport; then CLI and plugin stop loading the workspace themselves. | Each operation's parity test green; the in-process loader has no callers except loopback. |
| **6. Flip default** | `runtime-mode` default becomes shared daemon. | Weeks of betas with the LumeEditor peer session, zero incidents. |
| **7. Cleanup** | The in-process path exists only as attached `--no-daemon` mode; the delegation notice line is removed. | — |

**What #88 contributes.** Reused nearly as-is: framing, request/reply,
broadcasts, opaque ids, snapshot + projection, commands, task stream, the shared
build-step path (`build_run.lua`, already on master), the parity test. Re-cut:
runtime-mode values, handle fields, the runtime lock record and lost-lock exit,
version policy (range → match + frozen subset), idle default, launch
(`_spawn_daemon_if_possible` is detached but has none of the rest of the §19.9
recipe: cwd, env de-duplication, dev-source forwarding, early-exit detection),
routing (`_maybe_delegate_build` falls back to in-process
on any daemon error — it must instead follow §19.8/§19.9). New: auth, DACL,
operation lock, journal.

## 6. Spike findings that are now requirements

From the daemon lifetime spike:

- **Mutual HMAC handshake** from the machine trust key (§17.2), proofs bound to
  the pipe address; only `hello`/`auth` before authentication; broadcasts only to
  authenticated connections; 64 KiB pre-auth frame cap (§19.7).
- **Windows pipe DACL** via FFI `SetSecurityInfo`: owner + SYSTEM, deny NETWORK;
  the default descriptor is not enough (§19.6).
- **No inherited std handles on Windows** (the launching client must be able to
  exit and release its own pipeline while the daemon keeps running).
- **Forward the dev source** via `LOOMWORKS_LUA`, or a dev client launches a
  daemon running different code.
- **Neutral cwd** (per-user state dir), so the daemon never pins the workspace
  directory.
- **De-duplicated environment** before spawning.
- **Early exit detection** during readiness, so a daemon that cannot start
  fails fast instead of costing the full readiness timeout.
- **`stop` must end the process** — no timer or handle may keep the loop alive
  after shutdown.

## 7. Known risks

- **Windows job objects.** Terminals, IDEs and CI agents put children in a job
  that is killed on close; a detached daemon can die with its launcher. Benign:
  the lock goes stale and the next command relaunches (try
  `CREATE_BREAKAWAY_FROM_JOB` where permitted).
- **Unix socket path length** — short per-user socket directory, hashed name
  (§19.6).
- **EDR / AppLocker** may block or slow a resident, network-ish process; launch
  failure falls back to attached (§19.9), and `LOOMWORKS_NO_DAEMON=1` is the
  documented escape.
- **WSL and Windows on one checkout** — two hosts (and two machine keys) on the
  same `.nvim/`: the runtime lock and handle record host + OS, so one side sees
  the other's daemon as foreign and reports "busy on <host>" instead of
  connecting; the operation locks still serialize them.
- **Network drives** — heartbeat by mtime works across hosts but clock skew
  shifts staleness; locks record host so foreign holders are never killed.
- **Older versions** ignore the operation lock and journal — residual race of the
  same class as §2.7, documented.

## 8. Rejected alternatives

- **One-shot delegation** (spawn a fresh `lw` per build) — pays the cold start
  every time and keeps two writers.
- **Pure thin client without a projection** — a query per status-line redraw;
  LSP/DAP need a local model anyway.
- **Semantic-key wire identity** — renames rewrite keys in place; opaque ids
  localize rename handling in the daemon.
- **Per-object watches** — round-trip storms and non-atomic multi-object
  updates; broadcast + id-map is simpler.
- **A lifetime write-authority lock as the only safety** — superseded (§2).

## 9. Open questions

1. **Version-bypass vs "never a second writer".** D5 says one runtime; D7's busy
   mismatch case runs a command outside the runtime (safe only through the
   operation locks). Accept this as the one exception, or make the client wait
   for the busy daemon to drain instead?
2. **Editor code vs daemon binary.** The editor's client code ships with the
   plugin, the daemon with `lw`. Should the editor launch the resolved `lw` with
   `LOOMWORKS_LUA` pointing at the plugin's own source (daemon code = plugin
   code by construction), at the cost of CLI clients then mismatching that
   daemon?
3. **Attached runs vs a long-lived attached editor** (no `lw` binary): the editor
   holds the runtime lock for hours, so a CLI on PATH that the editor did not
   resolve gets "busy". Should an attached editor serve the endpoint too?
4. **Parallel CI jobs on one workspace** serialize on the runtime lock and fail
   after the brief wait — fine, or should `CI=true` wait longer?
5. **Single-file mutations and O.** Proposed: they do not take O (save guard
   covers them). Alternative: they check O and fail-fast while a multi-file
   operation runs — simpler to explain, more refusals.
6. **Journal discard command** — `lw unlock --journal` (proposed) or part of
   `lw nuke`?
7. **Daemon log location and retention** in the per-user state dir.
