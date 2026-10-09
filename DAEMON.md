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
| D6 | **Lifetime:** alive while any client is attached (editor keepalive), else exits after an idle timeout (default 1 h, configurable), or when the workspace root disappears. `lw daemon status`/`stop`/`restart`; a passive Runtime row in `lw status`. Handle records host and pid. | 1 h makes "mostly warm" the common case; shared drives need the host to avoid stopping a stranger's daemon. |
| D7 | **Version handshake:** protocol + lw version + schema versions. Idle mismatched daemon → restarted; busy → the client runs this command without it and the daemon retires when idle. | Same binary, so after `lw self-update` or a pin change a newer client meets an older daemon; never kill one serving others. |
| D8 | ~~**Editor:** launches `lw daemon run` from the `lw` it resolves (broker: `LOOMWORKS_LW` → repo pin → PATH → provisioned); with no `lw`, runs the daemon code inside nvim over loopback.~~ **Superseded** (see below): the editor is a pure `lw` client: it spawns `lw daemon run --stdio`, a connect-or-start relay to the workspace's shared daemon (step 5i, planned); if the shared daemon cannot be started the editor reports it and runs degraded (step 6b) — no private-daemon fallback. | Same runtime for editor and CLI; the plugin carries no binary-side Lua. |
| D11 | **Discoverable, versioned interfaces** (§19.20): `protocol` versions only the transport (framing, auth, handshake, envelope, flow control, root object); everything else is a named interface (`loomworks.Build/1`, `<module>.<Name>/1`) with its own version, listed by the root object's `describe` and chosen per call (highest common version). JSON Schema documents are the contract; old versions are adapters over the newest; protocol 10's kinds are v0 aliases until the deprecation window (two stable releases, ≥ 60 days) has passed. `lw_version` equality is a CLI policy, not a protocol rule; a connection is busy only while it owns a task or a command in flight. | Lets the editor and the binary ship separately (the split) and lets a non-Lua rewrite prove itself against the same schemas and transcripts; replaces the flat `protocol_min`/`caps` flags of the split proposal, which could not version a reshaped operation. |
| D9 | **Staged transition, locks first** (§5). Until every operation has moved, conflicting operations either fail or succeed — never an unknown state. | The in-process path, older versions and the daemon will coexist for months. |
| D10 | **Solid recovery from dead and hung holders** (§19.5). A dead holder (same host, process with that id and start time gone) is reclaimed automatically; a hung one (alive, heartbeat stale) is reported as hung and recovered with `--break-locks` on any lockable command (which also recovers a live, responsive holder right away: ask, ~5 s, kill; `=now` skips the wait), or `lw daemon stop --force` / `lw daemon kill`: ask → kill the process tree → verify → reclaim nonce-matched locks → recover state → run. Never kills on another host or the editor; `lw unlock --force` breaks a lock without killing. | A killed or hung process must never leave a workspace stuck, and recovery must be one command, also in CI. Start time guards pid reuse; nonce matching guards racing recoveries. A new flag name because `--force` on `lw build` already overrides artifact conflicts. |

The architecture choices of the earlier design are **kept**: daemon-authoritative
model with a client projection built by the same deserializer (§19.13);
session-local opaque ids for rename-stable wire identity (§19.12);
broadcast-everything coarse invalidation with seq + session generation; a
separate task stream with coalescing and bounded output (§19.15); three consumer
strategies (header / view-scoped / transient); FIFO commands whose effect returns
as a broadcast (§19.14); Lua for the daemon, with the protocol keeping a later
core rewrite possible.

### Superseded decisions

| Earlier decision (DAEMON.md on #88) | Superseded by | Why |
|--|--|--|
| **In-process is the PERMANENT default and fallback**; the daemon is an opt-in acceleration layer, never a hard dependency. | D1–D4: daemon is the end-state default; the fallback is the *same code* attached over loopback. | Two implementations of every operation means permanent parity debt, a fallback path that rots because nobody runs it, and two kinds of writer that can never be fully serialized. The robustness the fallback bought (CI, sandboxes, no binary) is kept by attached mode, which needs no background process. |
| Wire protocol versioned as a **compatibility range** `min_supported..current` (independently shipped sides). | D7: exact match for the CLI (same binary); protocol + schema match for the editor; a frozen control subset. | Client and daemon are one binary, so "compatible older daemon" only defers the restart; a range invites skew bugs. The frozen subset (auth, status, stop, retire) keeps any two versions able to talk long enough to fix the mismatch. |
| The daemon lock is the **write-authority token**; a client writes files only after taking it. | D5 + operation locks (§19.3): the runtime lock names the one runtime; per-operation locks + journal protect files. | During the transition the in-process path must write while a daemon runs; older versions never take the lock; a version-bypass run must be safe. Per-operation locks protect all of them; a lifetime lock protects none of them. |
| Idle timeout ~10 min. | D6: default 1 h, configurable. | Keep the daemon warm across a normal working session. |
| Separate `daemon` release channel / long-lived branch. | Opt-in `runtime-mode daemon` on master, step by step. | Each step is small and lock-safe on its own; a parallel line drifts (#88 already needed a full replay). |
| Stale-heartbeat reclaim for every holder (§16.6, master `build_lock`), and `lw daemon stop` falling back to killing the pid (#88). | D10: a same-host build (or any) lock whose holder is **alive but stale** is **no longer reclaimed automatically** — it is "hung" and needs `--break-locks`; a **dead** holder (process gone or pid reused) is reclaimed **immediately**, without waiting for the heartbeat window; other-host holders keep the heartbeat rule. Killing is explicit (`--break-locks`, `stop --force`, `kill`). | A hung but alive holder can resume and write after its lock was taken; a reused pid could be killed by mistake. |
| Broker may fall through to "bundled source, in-process". | D8: no binary → loopback inside nvim. | Same code either way; only the transport differs. |
| D8: no binary → the daemon code runs inside nvim over loopback. | The plugin/binary split: the editor connects to the shared daemon through `lw daemon run --stdio` (a relay, step 5i); when no binary is available or the shared daemon cannot be started, the editor runs degraded (step 6b). | Loopback inside nvim would force the plugin to carry all binary-side Lua forever, which the split must avoid. |
| Editor-owned child daemon `lw daemon run --stdio` as the editor's fallback (step 5p), and a separate `lw daemon attach --stdio` bridge (5i). | `--stdio` is always a connection (connect-or-start relay) to the one shared daemon, never a daemon; 5p dropped; no private-daemon fallback (step 5i, planned). | A private daemon was a second runtime the CLI could not share, and killing its pipe killed the editor's tasks *and* the runtime; one daemon per workspace, with tasks owned by connections, keeps both properties without a second kind of daemon. |
| D6: idle timeout 1 h; any attached client keeps the daemon alive. | Idle = no connections and no background work (step 5i); exit after a short grace, `IDLE_GRACE_SECONDS` = 45 s, configurable (step 5r B, done); background results persisted with timestamps and input fingerprints and reused on start (step 5r C, `loomworks.tool_cache`; done); `lw daemon status` shows the timeout in effect and the idle deadline (step 5r D, done once merged). | Warmth comes from persisted results rather than a resident process, so nothing lingers for an hour; the grace still spares scripts a cold start per command. |
| Split proposal: `protocol_min` + capability flags in the handshake, per-connection `used` set. | D11: a transport range only; interfaces discovered through `describe` and versioned per call. | Flags are a flat, unversioned stand-in for interfaces: they cannot express a reshaped operation or a module's own feature. |

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
| **1. Operation locks** | §19.3/§19.4 on the in-process path: `loomworks.op.lock`, lock-order audit (incl. device run vs build locks), nuke takes build locks, journal + recovery, lock records with start time + holder kind, dead/hung classification, `--break-locks`, `lw unlock --force` / `--journal`. | Concurrency tests: publish ∥ rename, nuke ∥ build, import ∥ publish; the §19.5 recovery tests (crash at every commit point → old or new; pid reuse; foreign host; editor-held). |
| **2. Lifetime** | Server + mutual HMAC auth (§19.8), Windows DACL, launch recipe (§19.10), lifetime rules (§19.11), version handshake (§19.9), `lw daemon status`/`stop`/`restart`/`kill` and `stop --force`, runtime log, Runtime row, `--no-daemon` (= in-process for now). Opt-in `runtime-mode daemon`: every workspace command keeps the daemon running though it only answers `ping`/`status`. | Weeks of daily use with the daemon resident: no stray processes, no stuck locks, clean restart after self-update, Windows job-object kills recover; §19.5 tests: daemon killed mid-build → automatic recovery, suspended daemon → reported hung, `--break-locks` recovers. |
| **3. First operation: `lw build`** | Re-cut #88's delegation (parity-tested there) onto step 1–2 foundations; all build forms. *Implemented (§19.15): every form routed in `runtime-mode daemon`, in the client's environment; `--break-locks` and interactive onboarding stay in-process.* | Build parity test; delegated builds in the LumeEditor peer session. |
| **4. Editor connects** | Plugin resolves `lw`, launches/connects, keepalive, observes task streams and model changes; still runs its own operations in-process. | CLI build visible live in the status page; editor reload/exit never orphans or kills a busy daemon. |
| **5. Remaining operations** | One at a time (configure/clean/reset, run/test, profile/project mutations, publish/import/pull, devices), each with a parity test; then CLI and plugin stop loading the workspace themselves. **5e — loopback** ships early, for the routed operations only (build, test, run preparation, clean, reset): in `runtime-mode daemon` the attached selections (`--no-daemon`, `LOOMWORKS_NO_DAEMON`, `CI`, the no-daemon setting, a failed launch) and `--break-locks` run them attached over loopback, holding R in `attached` mode (an attached `lw run` releases R when its preparation ends); the `in-process` default is unchanged. Mutations, publish/import/pull and devices follow with the §19.14 command machinery; the editor gets no loopback (D8 superseded) and no private daemon — when the shared daemon cannot be started it runs degraded (5i, 6b; 5p dropped). | Each operation's parity test green; the in-process loader has no callers except loopback. |
| **5f. Boundary guard** | Plugin/binary classification manifest and ratcheting guard test (`tests/split`, #149). No behaviour change. | Guard green; allow-list only shrinks. |
| **5g.1 Transport 11 + root** | Envelope (`call`, structured `error`, `signal`), `loomworks.Root/1` (describe, schema, subscribe, unsubscribe, objects_changed), `welcome.objects`, `protocol_min`; daemon accepts 10 and 11; one dispatch table with protocol 10's kinds as v0 aliases; meta-schema, transport, `Root/1`, `Common/1` documents; schema validator; lint + additive ratchet (§19.8, §19.20). | No behaviour change for protocol-10 clients; lint and ratchet green. |
| **5g.2 Existing operations as interfaces** | `Build/1`, `Tests/1.run`, `Launch/1.prepare_run`, `Toolchains/1.list`, `Profiles/1.compiler_cache`, `Workspace/1` (header, changed), `Tasks/1` (list, cancel, subscription), `lw.internal.Snapshot/1`; the CLI calls them; v0 kinds keep serving older editors; stdio conformance runner + transcripts. *Implemented. Part A: Workspace/1, Tasks/1, lw.internal.Snapshot/1, `lw daemon run --stdio`, the runner and the transcripts (with Root/1); part B: Build/1, Tests/1.run, Launch/1.prepare_run, Toolchains/1.list, Profiles/1.compiler_cache, Workspace/1.header_changed, string ids, the CLI's calls over transport 11.* | Conformance transcripts green; parity tests unchanged. |
| **5g.3 Policies** | `lw_version` equality as CLI policy via `describe` (§19.9); busy = owns a task or command; observer subscribes to `/tasks` and `/workspace` when offered, else v0; guard interface ratchet. *Implemented: `ensure.policy` compares `describe().binary.lw_version` over transport 11; `status.busy_clients` (connections owning a task or with a command in flight) decides idle vs busy, and a retiring daemon exits when none is; a transport-11 connection gets task frames, `model_change` and `retiring` only through its subscriptions (`Tasks/1`, `Workspace/1.changed`, the root signal); the observer subscribes when `welcome.objects` offers them; the guard checks every plugin-side `iface = ..., v = n` has a schema and transcripts.* | Editor survives a CLI-driven restart of an idle daemon. |
| **5h Provisioning** | Editor-side binary provisioning (schemas published per release). 5h.1 order: `LOOMWORKS_LW`, `binary.path`, system `lw` on PATH, plugin-managed (lw handles `lw.pin` itself); 5h.2 binary side; 5h.3 download/verify/prune. 5h.4 — the plugin carries the pinned `lw` version + a sha256 per host asset as a Lua module outside the bundle, the C/C+1 release sequencing that commits it, the CI interface check. 5h.5 *(done)* (spec §16.42, §19.9 "Editor retirement", §19.16 "Pre-launch probe", "Channel upgrades", "Retiring an incompatible daemon") — `binary.channel` (default unset = pin only): the pinned managed `lw` runs `lw release query --channel <c> --json` (signed sums + hash-verified descriptor), a newer release passing the interface check becomes the wanted managed binary (never below the pin; unstable->stable keeps a newer accepted pre-release until stable overtakes it; pruning keeps the pin's and the accepted channel's hash); a PATH / explicit `lw` is probed with `lw version --json` before the launch (definite failure skips a PATH `lw`, unknown does not, explicit is never replaced); the editor retires a daemon only when idle and incompatible (no transport overlap, no `loomworks.Root/1`, older schemas; a missing feature interface only degrades), never a newer or merely older one, once per `lw_version` per workspace per session. Parts (all done): spec; binary `release query`; probe; retirement; `binary.channel` (`provision/channel.lua`, `channel.json`). | The plugin reads none of lw's internal files for selection. |
| **5i Connections** *(spec done; PR B `daemon/connect.lua` and PR C relay + `--private` implemented; D-G planned)* | `lw daemon run --stdio` becomes a connect-or-start relay to the shared daemon (never a daemon; forwards frames opaquely; replaces the planned `lw daemon attach --stdio` bridge): reads the client's `hello` first, then connects, verifies `server_proof` before forwarding, adds `welcome.daemon` (the daemon's handshake versions) and `welcome.via = "relay"`; bounded buffering (`RELAY_HIGH_WATER` 4 MiB); waits up to `RELAY_RETIRE_WAIT` (60 s) on a retiring daemon, then launches the successor; `--no-launch` never launches, only waits (while stdin is open) for a daemon to appear and relays to it - the editor's form after `lw daemon stop` and while a retiring daemon is busy (exit 16 when that daemon is gone, so the editor launches the successor); `--no-launch --skip-instance <pid>:<start_time>` never relays to that daemon (the editor's after finding it incompatible; `welcome.daemon` carries its pid and start time) and waits for a successor, so no connect/reject loop; failures = nothing on stdout, one `lw:` line, exit statuses 10-16 (spec §19.10 "Relay exit status"). Every CLI command that already uses the daemon connects or starts likewise (no new command routed; `in-process` default unchanged); relays register nothing and `lw daemon list` / `kill --all --strays` show them as connections of their daemon (as with pin-redirect wrappers), while a `--stdio` process the runtime lock names is still a runtime (older pins). Tasks (build, test, run, configure, clean, reset) owned by the starting connection, cancelled when it closes; CLI Ctrl-C: first = graceful cancel and wait, second = close (force-stop); Windows: process-tree kill. Configure is connection-owned but not routed until 5j-5o; protocol-10 daemons: first Ctrl-C closes, as today. Idle = no connections and no background work (bounded by `BACKGROUND_MAX_DURATION`, 10 min). Conformance runner: isolated daemon per case via hidden `--private` (refused unless `LOOMWORKS_TEST_PRIVATE_STDIO=1`) or temp root. Pins 0.1.43-beta.15..the release before keep the old attached `--stdio`. A relay started by the editor applies the editor's compatibility rule (5h.5: retire only an idle incompatible daemon), not the CLI's `lw_version` equality, so it never restarts a compatible daemon; editor retirement goes through the relay connection, only when `welcome.via` is set. PRs: B `daemon/connect.lua` extraction; C relay + `--private`; D list/kill classification; E idle rule; F two-stage Ctrl-C; G editor uses the relay. | Editor and CLI share one daemon; killing a relay closes only its connection; no relay ever listed as a daemon or killed as a stray. |
| **5r Warm restarts** *(A-D done once merged; right after 5i; spec §19.11 "Warm restarts", §16.43)* | Idle grace `IDLE_GRACE_SECONDS` = 45 s replaces the 1 h default of `daemon-idle-timeout` (the setting still overrides it); tool detection (the only background result in 5r) persisted per module type in `tools.json` with a timestamp + inputs fingerprint (`lw` identity incl. `lw_version`, normalized PATH, PATHEXT, platform, module id + interface version, PATH directory mtimes), each type written atomically on completion, an interrupted type not written; a matching type is reused on start, a mismatch reruns only that type; the in-process CLI applies the same check. Parts: A spec, B idle grace, C tool cache, D (optional) idle deadline in `lw daemon status` (`status` reply `idle_timeout` / `idle_deadline`). | A script of several `lw` commands pays one cold start; a restart reuses unchanged results. |
| **5j–5o Editor on interfaces** | `view.Header/1` + `view.ProjectsIndex/1` (5j; spec §19.13 "Views": Header = `Workspace/1.header` fields + `config_set`, `diagnostics`, `trust`; ProjectsIndex = projects with id/key/type/path/abs_path + active configuration/tool key/state; `get` + `update` (full state, `initial`); one shape from the daemon or the same builder in-process; parts A guard *(done once merged)*, 0 spec *(done once merged)*, B daemon `daemon/views.lua` on `/views`, C editor view store + lualine/status header); editor operations as calls, `Launch/1.prepare_debug`, `DebugConfig/1`, task-runner tasks on `Tasks/1` (5k); `LspConfig/1` (5l); `Tests/1.discover` + `view.Tests/1` (5m); `view.Workspace/1` + `Devices/1` (5n); command methods of the model interfaces (5o). Each with schemas and transcripts. | Each consumer's allow-listed edges removed in its step. |
| ~~**5p Child daemon**~~ | **Dropped**: the editor connects through the 5i relay; no private-daemon fallback. The editor stops loading the workspace itself once 5j–5o are done. | — |
| **5q Module interfaces** | `M.interfaces` registration on `/modules/<id>`; first module interface in its own repo. Any time after 5g.2. | Module conformance in the module's CI. |
| **Retire protocol 10** | `protocol_min` → 11; v0 aliases deleted. | No in-repo v0 sender, and two stable releases and ≥ 60 days since the first stable release with 5g.3. |
| **6. Flip default** | `runtime-mode` default becomes the binary path for CLI and editor (shared daemon; degraded when it cannot be started); in-process editor kept one beta cycle behind `runtime.mode = "in-process"`. **6b**: in-process editor removed, no binary = degraded. **6c**: binary Lua moved to its own tree; schemas and transcripts become the cross-repo contract in a separate protocol repository. | Weeks of betas with the LumeEditor peer session, zero incidents. |
| **7. Cleanup** | The in-process path exists only as attached `--no-daemon` mode; the delegation notice line is removed. | — |
| **8a. Workspace data to `.lw/`** | lw's workspace data files move from `.nvim/` to `.lw/`: one-time migration recorded by a marker; refused when both exist and disagree. Deletion-safety review of every moved scope (`_safe_nvim_path`, nuke, housekeeping's `<root>/.nvim/tmp`, the launcher cache `.nvim/cache`); `lw bootstrap` `.gitignore` lines and a new launcher template generation (GENERATIONS). | Migration tests (fresh, migrated, both-disagree); deletion-safety review done. |
| **8b. Release v0.2.0** | `staging/daemon` → master once the daemon steps and 8a are done. | Stable release published. |
| **8c. Repository split** | This repository keeps only the Neovim plugin; CLI, daemon, `boot/`, `proto/`, the protocol spec, the release workflow and the launcher scripts move to a new repository with history (`git filter-repo`). Existing `lw.pin`/launchers download from the fixed release origin on `samienne/loomworks.nvim`, so releases stay or are mirrored there for a transition; the plugin's pin points at the new origin. | Old pins still resolve; plugin CI green against the new origin. |

**What #88 contributes.** Reused nearly as-is: framing, request/reply,
broadcasts, opaque ids, snapshot + projection, commands, task stream, the shared
build-step path (`build_run.lua`, already on master), the parity test. Re-cut:
runtime-mode values, handle fields, the runtime lock record and lost-lock exit,
version policy (range → match + frozen subset), idle default, launch
(`_spawn_daemon_if_possible` is detached but has none of the rest of the §19.10
recipe: cwd, env de-duplication, dev-source forwarding, early-exit detection),
routing (`_maybe_delegate_build` falls back to in-process
on any daemon error — it must instead follow §19.9/§19.10). New: auth, DACL,
operation lock, journal.

## 6. Spike findings that are now requirements

Evidence from the daemon lifetime spike (2026-09), each with its fix and where
§19 requires it:

| Finding | Evidence | Fix (verified) | §19 |
|--|--|--|--|
| The detached daemon inherited the client's std handles (libuv spawns with `bInheritHandles=TRUE` on Windows). | `lw build \| tail` hung **2 m 56 s**, until the daemon died. POSIX unaffected (fds 0–2 → `/dev/null`). | Clear `HANDLE_FLAG_INHERIT` on the std handles around the spawn: the same pipeline finished in **0.85 s**. | §19.10 |
| `daemon run` never exited after stop / idle-out: other handles kept the uv loop alive. | Three such processes from 2026-09-18 were still running and had to be killed. | `on_stop` ends the process. | §19.11 |
| The `--dev` source was not forwarded. | The child resolved a different source or died; the client waited the full 10 s. | Forward `LOOMWORKS_LUA`; stop waiting as soon as the child exits. | §19.10 |
| Daemon cwd inside the workspace. | Blocked rename, `git worktree remove` and `rm -rf` of the checkout on Windows for the whole idle window. | Neutral cwd (per-user state dir). | §19.10 |
| Windows pipe default DACL `D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;<owner>)(A;;FR;;;WD)(A;;FR;;;AN)`: Everyone and Anonymous READ, no `PIPE_REJECT_REMOTE_CLIENTS`. | A read-only peer that never sent `hello` received **2103 bytes** of another client's build output and broadcasts. With the HMAC handshake prototype: **0 bytes**. | FFI `SetSecurityInfo` after bind with `D:P(D;;GA;;;NU)(A;;GA;;;<user SID>)(A;;GA;;;SY)`, plus no broadcasts before authentication. | §19.7, §19.8 |
| The repository's `.nvim` grants Authenticated Users *Modify*. | The handle file is writable by other local users. | Never put a raw token in `hello` or the handle; mutual proofs bound to the endpoint, keyed from the per-user machine key. | §19.8 |
| Old host v0.1.2 forwards unknown commands to the bundle. | Re-exec of `daemon run` works there, given `LOOMWORKS_LUA` forwarding. | — (no host change needed) | §19.10 |
| The decoder had no frame-size limit before authentication. | — | 64 KiB pre-auth cap, checked on the length prefix. | §19.8 |
| `client.stop` removed the handle file even on an error reply. | — | Only the lock holder (or a reclaimer, §19.5) removes the handle. | §19.5, §19.11 |

## 7. Known risks

- **Windows job objects.** Terminals, IDEs and CI agents put children in a job
  that is killed on close; a detached daemon can die with its launcher. Benign:
  the lock goes stale and the next command relaunches (try
  `CREATE_BREAKAWAY_FROM_JOB` where permitted).
- **Unix socket path length** — short per-user socket directory, hashed name
  (§19.7).
- **EDR / AppLocker** may block or slow a resident, network-ish process; launch
  failure falls back to attached (§19.10), and `LOOMWORKS_NO_DAEMON=1` is the
  documented escape.
- **WSL and Windows on one checkout** — two hosts (and two machine keys) on the
  same `.nvim/`: the runtime lock and handle record host + OS, so one side sees
  the other's daemon as foreign and reports "busy on <host>" instead of
  connecting; the operation locks still serialize them.
- **Network drives** — heartbeat by mtime works across hosts but clock skew
  shifts staleness; locks record host so foreign holders are never killed.
- **Environment leakage** — `LOOMWORKS_LUA` and `LW_ROOT` forwarded to the
  daemon would leak into the build children it spawns. *Resolved for routed
  builds (step 3):* a step runs with exactly the requesting client's
  environment plus its own variables (§19.15), never the daemon's.
- **Stale environment (step 3)** — the daemon keeps the environment of the
  client that launched it. *Resolved (§19.15):* the client sends its whole
  environment with a routed build; the daemon runs the build's model work
  and its steps in it, and reloads its workspace when the environment differs
  from the one it was loaded in (declining while another build runs). Only
  the operations still in-process are unaffected, as before.
- **Known limitations of recovery** (§19.5): on Windows an `lw` holder in
  another console cannot reliably be interrupted, so recovery goes straight to
  the kill; process start time needs per-OS code (`GetProcessTimes`, `/proc`,
  `proc_pidinfo`), with heartbeat-only judgement where it is unavailable.
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

## 9. Resolved questions (working answers, revisitable)

1. **Version-bypass run is accepted** as the one exception to "one runtime":
   it is safe through the operation locks, and waiting for a busy daemon to
   drain could block for a whole build (§19.9).
2. **The editor launches the daemon from the resolved `lw`**, shared with the
   CLI — not from its own plugin source (§19.16).
3. **An attached editor will also serve the endpoint** (a shared daemon owned by
   the editor process) — future (§19.16).
4. **CI "busy" is fine**: parallel jobs use separate checkouts; the wait is
   configurable (`runtime-busy-wait`, §19.2).
5. **Single-file mutations do not take O**; they rely on the save guard (§19.3).
6. **A stuck journal** is discarded with `lw unlock --journal` (§19.4).
7. **Runtime log**: per-user state dir, one file per workspace, capped at a few
   MB with one rotation (§19.10).
8. **`--break-locks` against a live, responsive same-host holder** recovers
   right away: ask, wait about 5 s, kill; `=now` skips the wait. The same rule
   holds for `lw daemon stop --force` (§19.5).
9. **Recovery after a killed build** depends on the interrupted step: killed
   during configure → `unconfigured` (a half-written configure cannot be
   trusted); killed during the build step → not built (`configured`), and the
   build tool decides what to rebuild — no forced reconfigure; deletion-held
   directories keep `unknown` (§19.5, §5.7).

No open questions remain.
