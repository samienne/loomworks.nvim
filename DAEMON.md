# loomworks daemon — design

> **STATUS: DESIGN + Phase-0 rung-1 landed.** This document captures the planned
> architecture for a long-lived `lw` daemon and the separation of the `lw`
> runtime from the Neovim plugin. The daemon **server** is not built yet; the
> **bottom rung of §8's ladder is** — the mainline-safe foundations under
> `lua/loomworks/daemon/` (runtime-mode flag, handle file, wire protocol, the
> daemon **client stub** `lw daemon status|stop`, and the runtime broker),
> specified normatively in [`spec/core/daemon.md`](spec/core/daemon.md) §17. This
> is daemon *awareness* without daemon *capability*: no server, no delegation,
> nothing flipped off in-process. The daemon is developed **off mainline** (a
> separate branch / optional release channel) from Phase 1 on;
> **the in-process model stays the permanent default and fallback** on mainline
> the whole time — the daemon is an opt-in acceleration layer, never a hard
> dependency (see §8).
>
> Related: [`ARCHITECTURE.md`](ARCHITECTURE.md),
> [`spec/core/headless.md`](spec/core/headless.md) (§16 standalone/host),
> [`README.md`](README.md). This file is the design reference; normative spec
> sections (a future `spec/core/daemon.md`) are written per-phase as each lands.

---

## 1. Motivation

Today the Neovim plugin **is** the workspace: it holds the full domain model
in-process, owns file I/O, runs builds through overseer, and coordinates with
the `lw` CLI only through the three files on disk plus an advisory build-dir
lockfile. That works, but it has costs the daemon removes:

- **CLI cold-start.** Every `lw` invocation re-boots the workspace (read files,
  remerge, detect tools). Fine interactively; it adds up for agent/CI loops.
- **Editor↔CLI reconciliation lag.** The editor discovers a CLI-driven change
  by polling files (~2 s) and coordinates shared build dirs via an `O_EXCL`
  lockfile + mtime heartbeat (`build_lock.lua`). It works, but it is lag and
  ceremony, not live shared state.
- **No unified live view.** A build launched from `lw build` cannot stream its
  progress into the editor's status page as if launched from Neovim.
- **Plugins are Neovim-coupled.** Module/SDK logic runs in Neovim's Lua state,
  so a "module plugin" is a *Neovim* plugin even though almost all of its work
  (detection, build commands, device ops) is headless.

**Goal:** a single long-lived process per workspace that owns the authoritative
model + files + execution + coordination, which both the editor and the CLI
talk to — while the plugin keeps a thin, reactive projection for rendering and
Neovim-bound integration.

**Hard constraints (non-negotiable):**

- In-process/file-mode stays the **permanent default and fallback**. A client
  only ever *writes* files when it holds the per-folder write-authority lock
  (§4), so "permanent fallback" and "single writer" do not conflict. Daemon
  absent, crashed, or protocol-incompatible ⇒ the plugin runs exactly as today.
- **Non-invasive.** No auto-install; the plugin never silently downloads a
  binary (see §5).
- Read-only toward project sources, as today.

---

## 2. The pivotal decision: daemon-authoritative + client projection

Two models were considered:

- **(A) Pure thin client** — the plugin holds no model; every query is a socket
  round-trip. Rejected: latency on hot paths (winbar redraws), and Neovim-bound
  integration (LSP client, DAP, UI) means you never fully escape a client-side
  model anyway.
- **(B) Daemon-authoritative + client projection** — the daemon owns the model
  and files; the plugin keeps a **local projection** hydrated from the daemon,
  used for rendering and Neovim integration. Reads stay local (no per-query
  round-trip); only *sync* crosses the wire. **Chosen.**

**(B) reuses machinery you have, but it is not free.** `data_model.refresh` is
*source-agnostic* — it deserializes from parsed tables, not from disk — so the
projection client can reuse it, and `_apply(data, ctx)` still does
identity-preserving in-place updates the projection reuses. But `refresh` is
**not a pure function of `(config, cache)`**: it needs a live `deps` bundle —
resolved tool detection (a `tools_by_type` equivalent), the module registry,
`compute_build_dir`, plus publish provenance (`shared_baseline`, `user_*`
provenance, `intent_overrides`) — and it reaches into workspace/core state and
emits side effects (`data_model.lua:249,335-337,732-768`). Those are exactly the
things the plugin *sheds* to the daemon. **So the wire payload the daemon sends
the projection client is the resolved `deps` inputs, not just user/cache JSON**
— a real interface to define, not "raw data in." The genuinely new piece beyond
re-sourcing the deserializer is a **stable wire identity** (§3.2).

### One deserializer, two sources, two write-targets

```
                      ┌───────── nvim plugin ─────────┐
   files (fallback) ─▶│  data_model.refresh  ─────────│─▶ domain objects
   daemon wire  ─────▶│  (same deserializer,          │   (projection)
   (resolved deps)    │   fed resolved deps)          │
                      │                               │
   mutation:  in-process ─▶ write files (fallback)    │
              daemon-mode ─▶ send command ─▶ (effect returns as a broadcast)
                      └───────────────────────────────┘
```

- **One deserializer** (`data_model.refresh`), fed by **two sources**: files
  (standalone / fallback) or the daemon wire (primary), the wire carrying the
  resolved `deps` inputs above.
- **Two write-targets**: mutation methods write files today; in daemon-mode the
  same call sites send a **command** and the resulting change event refreshes
  the projection.
- **Domain logic stays reference-based** (honoring the "no runtime key lookup"
  principle); only the write path branches.
- The plugin **sheds** the complex parts (file I/O, remerge orchestration, cache
  writing, cross-process locking, build execution, tool detection) and **gains**
  mechanical parts (a sync client + a command sender). The end-state plugin is
  *simpler*, not doubled. The genuinely shared shapes are `types.lua` (already
  shared) plus the new resolved-`deps` wire schema.

### Ownership

| Concern | Daemon (authoritative) | Nvim plugin (projection + integration) |
|---|---|---|
| Files (user/cache/loomworks.json) | reads + **writes** (holds the write-authority lock, §4) | never writes unless it holds that lock (fallback) |
| Domain model construction | `data_model` from files | **same `data_model`, fed the resolved `deps` from the wire** |
| build / configure / clean / run / test | **executes + queues** | requests; renders streamed events |
| tool detection, fs-watch, locks | **owns** | — |
| mutations (config edit, publish, activate) | applies + persists | **sends as commands**, refreshes from the resulting event |
| pure accessors / derived queries | (has them too) | **runs locally on the projection** (no round-trip) |
| LSP client, nvim-dap, UI, log/device rendering | — | **owns** (consumes normalized data) |

---

## 3. Transport & protocol

Async throughout — a client **never blocks the Neovim main loop** on the socket.

### 3.1 Two message classes

- **Correlated request/reply.** Every client→daemon query or command carries a
  `req_id`; the reply echoes it. The client keeps a `req_id → callback` pending
  table, fires, and returns immediately.
- **Unsolicited broadcasts** (daemon→client). Model-change batches, task
  progress, notifications. No `req_id`; routed by object-id or event-kind.

**Mutations are effectively fire-and-forget:** their *effect* returns as a
broadcast (the change batch that re-renders), not as the reply — the reply is
only ack/error. So the common UI action does not wait on a round-trip.

**Command outcomes.** A command reply is one of `ok` / `rolled-back` /
`partially-applied`, reflecting the underlying mutation's real behavior — e.g.
`Workspace:rename_project` rolls back its in-memory changes if `_save_user`
fails but treats the subsequent `_save_cache` as best-effort
(`workspace.lua:5618-5642`), so a "succeeded but cache not yet persisted"
outcome is possible. An error reply MAY still carry the change batch for
whatever was applied before the failure; the client applies that batch and
surfaces the error.

**Ordering.** Commands are **FIFO-serialized by the single daemon**: a client is
guaranteed that its command's resulting change batch is broadcast before any
later command's batch, and a client that awaits its own ack has seen (or will
see, in order) the batch its command produced. Commands may interleave with
in-flight *async task* execution (a build in progress) but not with each other.

**In-flight on disconnect / idle.** A pipe disconnect (or a daemon that exits
mid-request) ⇒ the client rejects **all** pending `req_id` callbacks with a
typed `daemon_lost` error (which trips the fallback path, §4). A pending or
executing command counts as activity and **holds the daemon alive** — the idle
timer (§4) cannot fire while any command or task stream is outstanding, not only
while a build is actively streaming.

### 3.2 Wire identity — an opaque session id (a NEW layer)

Object references cannot cross a socket, so the wire needs a serializable token.
Use an **opaque, daemon-session-local id** (a monotonic integer). This is a
**new identity layer the daemon must maintain** — *not* a re-use of an existing
anchor. Today the domain model has **no stable id**:

- Deserialization anchors on **mutable semantic keys**: `data_model.lua:36-39`
  builds `ctx.projects[p.key]`, `ctx.config_units[cu.id]`, `ctx.profiles[pr.key]`,
  `ctx.config_sets[cs.name]`.
- A **rename rewrites those anchors in place.** `Workspace:rename_project`
  (`workspace.lua:5575`) sets `project.key = new_key` (`:5598`) and
  `unit.id = new_key.."/"..config_key` (`:5614`); `Project:rename_configuration`
  (`project.lua:549`) and `Workspace:rename_configuration_set` (`:5692`) do the
  same for their keys; `Profile:_derive_key` reassigns `self.key`
  (`profile.lua:302-321`). The only thing preserved across a rename is the
  **in-memory Lua-table pointer**. (These are distinct from
  `compute_profile_renames`/`apply_profile_renames`, `workspace.lua:5884/5909`,
  which re-key *profiles* when tools are added/removed — a different propagation.)

So the daemon keeps an **object → stable-id registry** (assigned once when an
object is first created, held for the daemon session):

- **Rename-stability is the payoff — and the reason to build it.** Because the id
  is independent of the semantic key, a rename becomes a single `renamed` event
  on the *same* id carrying the new key(s) — no client re-keying, no orphaned
  subscriptions. This value is what the new id layer buys; it is not something
  the code already does.
- **Re-attach after a file-driven refresh.** `data_model.refresh()` (external
  file change) re-matches objects by *semantic key*, producing possibly-new
  object tables. The daemon MUST re-attach each stable id to the refreshed object
  (match by semantic key across the refresh, carry the id forward) so ids stay
  stable across an external edit. This registry maintenance is the real cost of
  the opaque-id approach.
- **Session-generation tagged** — ids are session-local; a daemon restart
  reassigns them. The handshake (§4) carries a session generation; a new
  generation ⇒ the client flushes its id-map and re-hydrates.
- **Cross-references serialize as ids** (`ConfigUnit` payload carries
  `build_dir_id`, `configuration_id`, …), resolved id→object when the client
  builds the projection graph.
- **The client id→object map is a transport-layer router, NOT a domain
  key-lookup.** Domain logic never touches it; it lives at the serialization
  boundary.

### 3.3 Change signaling — broadcast, typed, batched

The model is small, so: **broadcast everything.**

- **Model-change events** — a small typed enum: `profile_activated`,
  `build_state_changed`, `config_changed`, **`renamed`** (a project / config /
  set / profile key changed — carries the stable id and the new key(s), §3.2),
  `publish_changed`, `devices_changed`, `error_state`. Delivered in
  **operation-scoped atomic batches** ("this daemon operation produced these N
  id-changes"), applied together, one re-render per batch. This preserves the
  atomic-swap consistency the current wholesale array-refresh has — at the
  natural granularity of one daemon operation.
- **The client's id-map *is* its subscription set.** The daemon broadcasts to
  all connected clients; a client applies changes whose id is in its map and
  ignores the rest. No per-client watch table on the daemon, no per-object watch
  registration on the client. "Don't hold what you're not showing" falls out:
  when the status page is closed only header ids are in the map.
- Typed events are used first as **scoped invalidation**, not deltas: an event
  says "this *kind* changed"; a subscriber whose view depends on that kind
  re-pulls its scope snapshot and refreshes. Deltas are a later optimization
  only if snapshot re-pull ever proves too heavy (it will not, at this scale).
- **Sequence + snapshot, with a cold-start rule.** A **per-workspace monotonic
  seq** counter stamps *both* snapshots and broadcasts. When a client opens a
  scope it: (1) starts buffering **every** incoming broadcast — *not* id-filtered,
  because the scope's ids are not yet in its map; (2) requests the scope snapshot
  (which carries the seq at which it was taken); (3) applies the snapshot; then
  (4) replays the buffered broadcasts with `seq > snapshot-seq` and resumes
  normal id-filtered handling. This closes the snapshot/stream race that a naive
  id-filter would leave open during hydration.
- **Removal / no reuse:** `removed: [id…]` events drop objects; ids are
  monotonic and never reused within a session.

### 3.4 Task stream (ephemeral) and presentation events

- **Task event stream** — high-frequency `progress` / `output` for a running
  build/op. Kept **separate** from model changes (progress ticks must not churn
  the model). **Workspace-scoped and observable by any client**, so a
  CLI-launched `lw build` streams into the editor's status page identically to
  an editor-launched build. The *durable* outcome arrives as `build_state_changed`
  when the task completes.
- **Backpressure.** The task stream is high-volume and the Neovim client drains
  it on the main loop, so a slow client can let the daemon's libuv write buffer
  grow. The daemon **coalesces** progress (only the latest fraction per task
  matters) and MAY **drop / rate-limit** `output` into a bounded per-task ring
  when a client is not keeping up. Model-change batches (§3.3) are **never**
  dropped — they are small and correctness-bearing. A client that falls too far
  behind is dropped and must reconnect + re-hydrate.
- **Notifications** — one new event kind `notify{ level, title, message,
  task_id? }`, rendered as `vim.notify` (nvim) / stderr (CLI).
- **Fidgets** — not a new channel: the Neovim rendering of the task progress
  stream. Targeting (which client shows what) is a policy knob tied to
  task-observation, not a structural concern.

### 3.5 Client consumer strategies

Match the strategy to the consumer — there is no single one:

- **Always-warm header** (winbar / lualine): `{ active profile, build glyph,
  error state, … }`. Bounded and cheap; delivered in the `welcome` handshake
  (§4) and kept fresh by broadcasts. Exists because winbar redraws dozens of
  times/sec and **cannot** tolerate a per-redraw query.
- **View-scoped full model** (status page): hydrated on open (one scope
  snapshot, a few ms, via the §3.3 cold-start rule), kept fresh by typed events
  while open, dropped on close.
- **Thin-query transients** (pickers / launch / commands): query on invoke, act,
  discard — no warm model.

---

## 4. Lifecycle

- **Launch-if-absent.** Both the editor and the CLI start the daemon if none is
  running for the workspace. The spawn race is resolved with the **same `O_EXCL`
  + mtime-heartbeat primitive** `build_lock.lua` uses — but a **new, per-folder
  lockfile** (e.g. `.nvim/loomworks.daemon.lock`), *not* `build_lock` literally:
  `build_lock.M.acquire` is hard-wired to `<build_dir>.loomworks-lock` naming and
  a build/configure/clean action (`build_lock.lua:26,91`). Same idea, distinct
  lock.
- **The per-folder primary lock is the write-authority token.** Exactly one
  process holds it; the holder is the sole writer of `user.json` / cache /
  `loomworks.json`. This is what makes "single writer" and "permanent
  file-writing fallback" consistent: **a client enters the file-writing fallback
  lane only after it acquires the primary lock itself — never on a bare socket
  error.** A dropped pipe means "reconnect or respawn the daemon," not "assume
  the writer role." A client becomes writer only when the lock is genuinely free
  — the previous holder released it, or its heartbeat went stale and the lock was
  reclaimed. If a client force-reclaims a stale lock from a hung daemon, that
  daemon's in-flight writes are abandoned; the reclaiming writer **re-reads
  current file state before writing** (the files, not the dead daemon's memory,
  are the recovery point — cache already reflects "unknown" before async work,
  per the existing crash-safety rule). Two writers can never race.
- **Idle timeout (~10 min).** Reset on any client activity — a request, a
  keepalive ping, or an outstanding command / task stream (§3.1). The editor
  holds a lightweight keepalive while its workspace is loaded; **multiple editors
  each hold one**, and the idle timer does not start while any is attached. No
  clients + no recent CLI activity for the window ⇒ the daemon releases the
  primary lock and exits.
- **Connect handshake.** On connect a client sends `hello{ protocol_version }`;
  the daemon replies `welcome{ session_generation, protocol_version,
  header_snapshot, current_seq }` — giving the client the always-warm header
  (§3.5), the seq watermark to base scope hydration on (§3.3), and the generation
  to detect a restart. A protocol mismatch is resolved per §5.3 before any other
  message.
- **Handle file** `.nvim/loomworks.daemon.json`:
  `{ pid, pipe, protocol_version, lw_version, session_generation, started_at }`.
  Clients read it to find the pipe and version, health-check, and respawn on a
  stale/incompatible handle. The **lockfile** (write-authority) and the **handle
  file** (discovery) are separate concerns.
- **Liveness** uses the mtime-heartbeat trick (not `uv.kill(pid,0)`, unreliable
  on Windows) — the lesson `build_lock.lua` already encodes
  (`build_lock.lua:23-24,55-57`).
- **Transport + security.** libuv pipes both ends — `uv.new_pipe`/`listen`
  (daemon), `vim.uv`/`sockconnect` (nvim). **The pipe is a trust boundary:** any
  local peer that can open it can issue mutation and **build** commands, and in
  Phase 2 cause arbitrary **lw-plugin Lua** to run — i.e. code execution as the
  daemon's owner. So the endpoint MUST be owner-restricted: a Unix socket in a
  `0700` directory owned by the user (plus a `SO_PEERCRED`/`getpeereid` owner
  check), and a Windows named pipe created with a security descriptor granting
  the owner only. Detached, console-less spawn on Windows is the other fiddly
  part; budget for both.
- **Degradation** (per the write-authority rule above): unreachable / crashed /
  protocol-incompatible daemon ⇒ the plugin reconnects/respawns, and *only if it
  can take the primary lock* does it fall back to building the model from files
  itself. The daemon can never fully break the editor, and two writers can never
  race.

---

## 5. Runtime resolution, install & versioning

### 5.1 The daemon binary *is* the `lw` binary

The daemon is `lw daemon`. So "how do we ship a daemon" reduces to the
already-solved `lw` distribution problem (signed releases, the pin, the update
**channels** in `spec/core/headless.md` §16.29). For an *unpinned* workspace the
plugin can even run the daemon from `luvi` + its **own on-disk source** (running
from a dev source — distinct from *installing* from one, which `boot/install.lua`
refuses) — then plugin and daemon are the same version by construction, and only
a bare `luvi` runtime needs to exist.

### 5.2 Runtime broker (resolution precedence)

A **new, plugin-side** resolution chain — distinct from the launcher's
system-Lua precedence (§16.11) and the pin-redirect order (§16.23); see the note
below:

```
LOOMWORKS_LW  →  repo pin (.nvim/…)  →  system `lw` on PATH
   →  nvim-data cached runtime  →  fetch (CONSENTED)  →  bundled/dev (plugin dir, in-process)
```

- **Never auto-install.** If nothing on the chain is present, the plugin runs
  in-process from its own source, exactly as today. A consented install
  (`:LoomworksProvision`-style) lands in `stdpath("data")/loomworks/…-<ver>/`
  (versioned, GC-able) — never on startup, never silently.
- **Compatibility floor (a range).** A system `lw` is used only if its wire
  protocol is within the plugin's supported range `min_supported..current`
  (§5.3); too old/incompatible ⇒ fall through.
- **Pin is the per-folder version authority.** A pinned workspace's daemon runs
  the pinned version; a mirror/`release-url` override supersedes channel
  resolution. A **channel** override (the existing top-level `channel` config /
  `LOOMWORKS_CHANNEL` env, `boot/update.lua:65`) selects which release track the
  runtime is fetched from — e.g. a `daemon` channel (§8) to dogfood daemon
  builds on one machine while others stay stable. If a nested `runtime.channel`
  key is introduced it **supersedes** the top-level `channel` for runtime
  resolution only; prefer reusing the top-level key unless a per-concern split is
  actually needed.
- **Note on precedence vs the launcher.** §16.11 puts a *dev source* at HIGH
  precedence (an explicit opt-in, above release); this broker chain ends with
  `bundled/dev` as a *last-resort fallback*. Different orderings for different
  purposes — the launcher chooses what to *execute now*, the broker chooses what
  daemon runtime to *drive*. Reconcile the dev-source meaning explicitly when
  implementing: an explicit `LOOMWORKS_LW`/dev opt-in stays high; the bundled
  plugin source is the fallback.

### 5.3 Version mismatch policy

A client driving a daemon must match its **wire protocol**, not its exact code
version (the plugin's own source is used only for the fallback + Neovim
integration). The wire protocol is versioned as a **supported range
`min_supported..current`** — a client accepts a daemon whose protocol falls in
its range, and vice-versa — exchanged in the `hello`/`welcome` handshake (§4).

This is deliberately **unlike** the `api_versions.lua` module/SDK doctrine, which
is strict-equality *lockstep within one release* (`api_versions.lua:6-16`)
because there you control both sides in the same build. The daemon's whole
premise is a client and a daemon at **independently-shipped versions**, which
needs a compat range, not lockstep — so the wire protocol does **not** follow the
`api_versions` doctrine. On an *incompatible* daemon (protocol outside the range):

| Client | Can it fix itself? | Policy |
|---|---|---|
| **CLI** | yes — self-upgrade to the pin; owns daemons it spawns | drain-and-restart a stale-vs-pin daemon; **error with guidance** against a plugin-owned daemon it cannot use — never force a takeover |
| **Plugin** | no — cannot rebuild its source mid-session | **fall back to in-process**, surface an inline notice; never kills a daemon another client may be using |

Governing rule: **a version mismatch never lets one client kill a daemon out
from under another.** Idle timeout bounds staleness; `lw daemon restart` is the
explicit escape.

---

## 6. Plugins become "lw plugins"; presentation generalizes

### 6.1 The plugin-host split

Once the daemon owns build execution and detection, module/SDK logic runs *in
the daemon*, not Neovim. The plugin API splits along a line that already
half-exists (opaque `lsp_configs`):

- **Portable half → daemon-hosted "lw plugins":** `info`, tool detection,
  `parse_targets`, configure/build/clean commands, devices, tests, and
  `lsp_configs` (opaque data crosses the wire trivially). No Neovim code.
- **Editor-integration half → stays nvim-side:** DAP adapter wiring, the
  `vim.lsp` client, UI. These consume daemon output.

### 6.2 Device/log generalization (design now, migrate later)

The special `loomworks-module-ohos.nvim` should largely disappear: its device
logic (`hdc install/launch/hilog`) is all headless ⇒ an lw plugin. The main
plugin gains **general** device/log presentation — a device picker and a **log
viewer** driven by a normalized log-record schema `{ ts, level, tag, pid,
message, fields? }` with a `fields` typed escape hatch for platform extras.
Device-log streaming is the natural streaming reference for the task stream
(§3.4). Migrate `ohos` to an lw plugin only when it is being actively developed
again.

### 6.3 Subsystems that straddle the wire (explicit daemon-line work)

Several existing subsystems do **not** split cleanly into "logic → daemon,
UI → nvim" and need designed handoffs — none are free:

- **`session_tracker.lua`** orchestrates build → deploy → device-install →
  **dap**, with a fidget spanning build-start → `event_initialized` and a confirm
  dialog when a session is already active. build/deploy/device-install move
  daemon-side, but `dap.run` is client-side (§6.1). So the chain straddles the
  wire: a daemon **build/deploy completion event** must trigger the
  **client-side** dap launch; the session-active **confirmation** stays
  client-side (it is UI); the fidget is driven by the daemon task stream (§3.4)
  up to the handoff, then by client-side dap events. Specify this handoff in
  Phase 1/2.
- **neotest + loomtest adapters** call ConfigUnit/TestUnit methods **in-process**
  today, and the neotest adapter already fights nio-coroutine hangs. Moving test
  execution daemon-side turns those direct calls into **async round-trips inside
  nio coroutines** — a known-fragile combination. Treat test-execution-over-wire
  as a **risky, explicitly-deferred** Phase-2 integration; the in-process test
  path can remain (tests run where the plugin runs) even after builds move to the
  daemon.
- **Publish/intent buffer flow** — `:w`→`publish`, `:e!`→`revert_to_baseline`,
  the `P` intent cycle, per-item `publish_one`/`revert_one`, and the
  sticky-intent / `shared_baseline` state — is a substantial subsystem whose
  mutations must map to **daemon commands** (with `publish_changed` broadcasts,
  §3.3) while the buffer UX (BufReadCmd/BufWriteCmd, Vim `E37` on a dirty buffer)
  stays client-side. Enumerate these command mappings before Phase 1 touches the
  status buffer.

### 6.4 Language

Stay Lua. The wire protocol *preserves the option* to rewrite the daemon core
later (e.g. Rust with an embedded Lua VM via `mlua`, so existing Lua module
plugins survive) — Neovim never notices behind the protocol. Design for the
switch (clean protocol + embeddable-Lua assumption); do not spend it. Neovim's
side is unavoidably Lua, so any switch is a two-language system.

---

## 7. Testing strategy

- **Runtime-mode flag** — `runtime = { mode = "in-process" | "daemon" | "auto" }`
  plus `LOOMWORKS_RUNTIME` for quick A/B. Default in-process. This is both the
  dev switch and the permanent fallback.
- **Parity / differential testing (the gold standard).** Because both backends
  share `data_model` + serialization, run the same operation through both and
  **diff the serialized workspace** — they must be byte-identical. Run the
  existing suite against *both* backends. The daemon is "correct" when it
  produces the same model state as in-process for the same inputs.
- **CLI-first, headless, before nvim.** Validate the daemon's protocol,
  lifecycle, execution, and broadcast entirely through `lw` + a **two-client
  headless harness** (spawn daemon, connect A and B, build from A, assert B's
  projection updates). The existing CLI e2e already catches shim-only bugs. Wire
  the nvim projection client last, on a proven core.
- **Dogfood** the daemon line via `runtime.mode = daemon` + a dev-source (or
  `daemon`-channel) runtime while everything else stays in-process (§8).

---

## 8. Rollout: a separate line, not a mainline rewrite

The daemon is developed **off mainline** and only promoted once it is good
enough — mainline stays in-process for normal operation the whole time. Two
independent axes control this:

1. **The runtime mode flag** — `runtime = { mode = "in-process" | "daemon" |
   "auto" }` (+ `LOOMWORKS_RUNTIME`). The **in-build** toggle and permanent
   fallback: even a build that *contains* daemon code defaults to in-process and
   falls back to it (§4).
2. **The distribution line** — the daemon work lives on a **separate branch** and
   ships on an optional **`daemon` release channel**, keeping daemon code off the
   stable/`unstable` mainline until proven. Switch a machine onto it with
   `lw self-update --channel daemon` (and `mode = daemon`); switch back by
   self-updating to stable. **Promotion** climbs the ladder below, ending at the
   same-binary flag model — that is the *destination*, not the starting point;
   the flag always remains the fallback.

**The `daemon` channel needs the channel→label-matcher refactor.** Today
`unstable` resolves "newest of *any* prerelease," so `-daemon.N` tags would leak
into `unstable` (`spec/core/headless.md` §16.29). Two ways there:

- **(A)** Do the small channel→label-matcher refactor (each channel = a tag-label
  predicate; `unstable` = `-beta`/`-rc`, `daemon` = `-daemon.*`) when the
  dedicated channel is actually wanted.
- **(B, recommended for early development)** Skip the channel entirely at first:
  dogfood the daemon branch via `runtime.mode = daemon` + a **dev-source**
  runtime (run the daemon from the branch checkout, §5.1). No release, no
  refactor. Add the `daemon` channel later, once the branch is worth distributing
  to a second machine.

### Promotion ladder

The same-binary, flag-gated model — one binary that runs either backend and can
stop a daemon it finds — is attractive precisely because it makes A/B testing and
lifecycle trivial. But it is the **destination**, reached by promotion, not where
development starts. The "can't break existing functionality" cost of daemon code
living in mainline applies only while the daemon is breakage-prone — and that
phase lives on the branch, so the cost never lands on mainline users.

1. **Seams + client stub → mainline** (Phase 0). Executor/source seams with
   in-process the *only* backend, plus the daemon client stub. A pure refactor,
   parity-testable, nothing observable changes — low mainline risk.
2. **Daemon backend incubates on the branch** (Phase 1). It is a *separate
   backend behind the seam* and mostly **new files** (daemon process, protocol,
   projection client), so it barely conflicts with mainline (cheap drift) and you
   can break it freely. Dogfood via `mode=daemon` + dev-source. This is the only
   rung where "don't break mainline" is relaxed — because you are not on mainline.
3. **Promote behind a default-off flag** once the backend is stable and
   parity-green. Merge to master with `mode` defaulting to in-process. Now you
   have the same-binary benefits — trivial A/B, in-repo parity across both
   backends in one run, unified lifecycle, one binary to ship — with zero risk to
   default users, who never flip the flag.
4. **Flip the default to daemon** last, once proven across machines; the flag
   stays as the permanent fallback (§1, §4).

**Why each rung is safe/cheap:** the seam keeps the two backends separate (daemon
work rarely touches in-process code); parity tests catch an in-process regression
the moment it appears; the default-off flag makes the rung-3 promotion invisible
to users; and the daemon being mostly additive files keeps branch drift and merge
cost low.

### Phases (on the daemon line unless noted)

- **Phase 0 — runtime separation (MAINLINE, no daemon).** The runtime-mode flag
  + the source seam + the broker (§5). Its mainline win is **runtime *resolution*
  only**: the editor can resolve and launch a system / released / pinned `lw`
  (version consistency with the CLI, and the launcher a daemon will later need).
  It does **not** delegate builds — with no daemon, delegation could only mean
  spawning a fresh `lw` per build, the one-shot delegation §9 rejects. So on
  mainline Phase 0 the editor still **builds in-process**; only resolution/launch
  is new. Mainline also gains a daemon **client stub** — detect a running daemon
  via the handle file and `lw daemon stop` it (connect + `shutdown`, pid-kill
  fallback) — so any `lw`, daemon-capable or not, can retire a stray daemon when
  the user goes daemonless. This is daemon-*awareness* without daemon-*capability*,
  and it works in both the branch and the same-binary model. (The executor seam's
  shape — how a delegated build's task stream is consumed — is a Phase-1 concern,
  so the seam is finalized on the daemon line, not mainline.)
- **Phase 1 — daemon + shared-deserializer wiring (daemon line).** The daemon
  owns files + execution + queue + lifecycle; the plugin feeds `data_model` from
  the wire (the resolved-`deps` payload, §2) or files (fallback); mutations
  become commands. The protocol (§3, §4) is shaped here. One model-inversion, not
  two half-steps.
- **Phase 2 — device generalization / lw-plugins (daemon line).** The
  plugin-host split and general device/log presentation (§6.1–6.2), plus the
  straddling-subsystem handoffs (§6.3). Design now; migrate `ohos` when active.

Each phase is stoppable: mainline Phase 0 stands alone (editor uses a
system/released `lw`); the daemon line can pause after Phase 1 (a working daemon,
no plugin generalization).

---

## 9. Rejected alternatives (and why)

- **One-shot delegation (spawn a fresh `lw` per build).** Reintroduces the
  cold-start cost the daemon removes, and its "plugin owns files, reads build
  results back" code is thrown away once the daemon owns files. Skip it — go
  daemon-first for delegation; mainline Phase 0 keeps builds in-process (§8).
- **Pure nvim thin-client (every query over the wire).** Latency on hot paths;
  and Neovim-bound integration means the client-side model never fully goes
  away, so you pay the whole rewrite for a partial win.
- **Semantic-path wire identity (`workspace.projects.my-project`).** A path *is*
  the mutable semantic key, which renames rewrite in place (§3.2), so
  path-addressed subscriptions would need distributed re-keying on every rename
  and would orphan in-flight messages. The opaque-id registry (§3.2) is **new
  work**, but it localizes rename handling to the daemon (one `renamed` event on
  a stable id) instead of spreading re-keying across every client — which is why
  it is worth building despite not being free.
- **Per-object watches.** Round-trip storm for the status page, a
  watch-registration/GC explosion, and cross-object inconsistency (non-atomic
  multi-object notifications). Broadcast-everything + the id-map-as-subscription
  is simpler and atomic per operation.

---

## 10. Open questions

**Decide before Phase 0 (foundational):**

- **Write-authority rule (§4).** Confirm the per-folder primary lock is the sole
  gate for entering the file-writing fallback (a client writes files only when it
  holds the lock, never on a bare socket error). All single-writer safety rests
  on this.
- **Pipe permission model (§4).** Owner-only socket dir / named-pipe security
  descriptor + peer-owner check, and explicit acknowledgement that the pipe is a
  code-execution surface.
- **Does mainline Phase 0 involve any build delegation? (§8).** Decision: **no**
  — mainline Phase 0 is resolution/launch only; delegation is daemon-line.
  Confirm so Phase 0 does not smuggle in one-shot delegation.
- **`daemon` channel now vs dogfood-via-mode (§8, A/B).** Recommended: **B**
  (dev-source + `mode=daemon`) early; add the channel + label-matcher refactor
  later.

**Decide per-phase (detail):**

- Default `runtime.mode`/channel for a **dev checkout** (so normal plugin
  iteration doesn't accidentally drive a stale released daemon).
- **Progress rendering** for delegated builds: overseer-as-a-view of the task
  stream vs a lighter fidget/session_tracker display.
- Snapshot-refresh vs incremental **deltas** (start coarse; add deltas only if
  measured to matter).
- **Backpressure** drop/coalesce specifics for the task stream (§3.4).
