> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.
>
> This file is written **per-phase** as the daemon line lands (see
> [`../../DAEMON.md`](../../DAEMON.md), the design overview, and its §8 promotion
> ladder). It specifies: the runtime-mode flag, the handle file, wire-protocol
> versioning, the client stub, and the broker (§17.1–17.5); and the **daemon
> server** run loop — lifecycle, write-authority lock, and owner-restricted pipe
> (§17.6–17.8). The projection client, commands, and broadcasts land in the
> sections that follow as each phase is implemented.

## 17. Daemon Runtime

The system runs its workspace either **in-process** — the editor or CLI process
*is* the workspace, as in §1–§16 — or by driving a long-lived **daemon** that
owns the model, files, and execution and serves both the editor and the CLI. The
runtime-mode flag (§17.1) selects between them; the handle (§17.2), wire protocol
(§17.3), client (§17.4), and broker (§17.5) are the discovery and resolution
layer; the server (§17.6) is the daemon process itself.

**In-process is the permanent default and fallback.** Every contract in §1–§16
holds unchanged when the daemon is absent, crashed, or protocol-incompatible: the
resolved runtime falls back to in-process. The daemon is an opt-in acceleration
layer selected behind the flag, never a hard dependency, and enabling it never
regresses the in-process path.

### 17.1 Runtime mode

A **runtime mode** selects the execution backend. Its values are `in-process`,
`daemon`, and `auto`. The default is `in-process`, which is also the permanent
fallback (§17.4, and DAEMON.md §1/§4).

The **effective** mode is resolved by precedence: an environment override, then
host configuration, then the default. An invalid value at either configured
layer is ignored — resolution falls through to the next source and reports the
problem — so a typo degrades **to** the in-process default, never into an
undefined state. Resolution is a pure function of its inputs and never launches
or connects to anything.

In Phase 0 the resolved mode is **informational**: because no daemon backend
exists on mainline, execution stays in-process regardless of the mode. A host
MUST expose the resolved mode for inspection (§17.4) but MUST NOT change build,
run, test, clean, or configure behavior based on it.

The interactive editor host reads the mode from its setup options
(`runtime.mode`); the non-interactive host reads it from its own settings
(`runtime-mode`). Both honor the same environment override (`LOOMWORKS_RUNTIME`).

### 17.2 The daemon handle file

A daemon publishes a per-workspace **handle file** at
`<root>/.nvim/loomworks.daemon.json` as its **discovery** record. It carries the
daemon's process id, its endpoint (a local pipe), the wire-protocol version and
implementation version it speaks, a session generation, and a start timestamp.

**Liveness is judged by an mtime heartbeat, never by a pid liveness probe** — a
running daemon refreshes the handle's modification time on a timer, and a handle
whose mtime has not advanced within a bounded window is **stale** (its daemon is
crashed or hung). This is the same host-neutral liveness rule the build-dir lock
uses (§16.6): a pid-existence check is unreliable across hosts.

The handle file is a **discovery** artifact only. It is distinct from the
per-folder **write-authority** lock (a later phase, reusing the §16.6 O_EXCL +
heartbeat primitive under a different name): discovery says *where a daemon is*,
write-authority says *who may write the workspace files*. A client MUST NOT infer
write authority from the handle file.

Reading the handle is tolerant: a malformed or unreadable handle yields no usable
daemon record rather than an error, and is **never mistaken for a live daemon** —
a present-but-corrupt handle (empty or non-decoding) reports as unreadable, not as
running, so a client neither trusts it nor is confused by it (`lw daemon status`
says the handle is present but unreadable and offers to clear it).

### 17.3 Wire protocol versioning

The daemon and its clients are shipped at **independently chosen versions**. The
wire protocol is therefore versioned as a **supported range**
`min_supported..current`, and a peer is compatible when its protocol version
falls inside the local range. This is deliberately **unlike** the strict-equality
lockstep the plugin-interface versions use (§8.0), which governs a module/SDK and
a host built together; the daemon's premise is two independently-shipped sides,
which needs a compatibility range, not lockstep.

An incompatible peer is reported, never silently driven. A client MUST NOT kill a
daemon merely because it is version-incompatible (§17.4).

### 17.4 The client stub: detect and stop

A host MUST provide two daemon-client operations even when it ships no daemon
server:

- **Detect** — read the handle (§17.2) and report whether a daemon is present,
  whether it appears live (heartbeat within the window), and whether its protocol
  is compatible (§17.3). Detection performs no connection and no mutation.

- **Stop** — retire the workspace's daemon, if any. Stop first attempts a
  **graceful shutdown** over the daemon's pipe; on a connection failure or an
  acknowledgement timeout it **falls back to terminating the handle's process**.
  The handle file is removed once the daemon is gone. Stopping when no daemon is
  present is a no-op success (nothing to stop), not an error.

All client I/O is asynchronous and MUST NOT block the editor's main loop.

The non-interactive host surfaces these as `daemon status` (detect; also reports
the effective runtime mode, §17.1) and `daemon stop`. This lets **any** host —
daemon-capable or not — inspect and retire a stray daemon, e.g. after a machine
is switched back to in-process operation. Neither operation ever *launches* a
daemon.

### 17.5 The runtime broker

The **broker** resolves *which* runtime a daemon would be driven from, by
precedence: an explicit runtime override, then a repository version pin (§16.21),
then a compatible host on the system search path, then a previously-provisioned
runtime under the host data directory, then — only with explicit consent — a
fetch, and finally the host's own bundled source, run in-process.

Two rules are normative:

- **Never auto-install.** The broker never triggers a fetch as a side effect of
  resolution; an unresolved chain falls straight through to the in-process
  fallback, exactly as today. A fetch happens only on a distinct, explicitly
  consented management action (§16.13).
- **In-process is always reachable.** The bundled host source is always available
  as the last-resort resolution, so the daemon is never a hard dependency
  (§17.1).

This broker chain is **distinct** from the launcher's system-source precedence
(§16.11) and the pin-aware redirect (§16.23): those choose what to *execute now*;
the broker chooses what runtime a daemon would be *driven from*. The broker
**resolves only** — it never spawns and never installs.

The broker MAY **probe** a resolved system host for wire-protocol compatibility
before choosing it (§17.3), by invoking it to report its protocol version; a host
whose protocol falls outside the local supported range is rejected and the chain
falls through. Probing is optional and best-effort — a host that cannot be probed
is reported with the probe still owed, never silently trusted or silently
discarded.

### 17.6 The daemon server

The **daemon server** is one long-lived process per workspace, started by
`daemon run`. On start it MUST, in order: acquire the workspace's
**write-authority lock** (§17.7) — refusing to start if another live daemon holds
it (single primary per folder); bind and listen on the **owner-restricted pipe**
(§17.8); publish the **handle file** (§17.2) naming that pipe, its pid, protocol
version, lw version, and a fresh **session generation**; and begin heartbeating
the handle and lock so their liveness stays fresh (§17.2). A start that cannot
complete these leaves no partial state — the lock and any bound pipe are released.

The server maintains a per-workspace **monotonic sequence counter** that stamps
snapshots and broadcasts (used by the projection layer). Its **session
generation** is session-local and reassigned on every restart, so a client that
sees a new generation flushes any cached wire identity and re-hydrates.

Message handling has two classes (DAEMON.md §3.1): **correlated request/reply** —
every client request carries a `req_id` the reply echoes — and **unsolicited
broadcasts** to all connected clients (no `req_id`). On connect a client sends
`hello{ protocol_version }`; the server replies `welcome{ session_generation,
protocol_version, min_supported, current_seq, … }`, giving the client the seq
watermark to base hydration on and the generation to detect a restart (§4). An
unknown message kind, a malformed frame, or a handler error yields a typed error
reply, never a crash. A `shutdown` request is acknowledged and then stops the
server; a keepalive `ping` resets the idle timer.

**Idle timeout.** With no clients attached and no activity for a bounded window
(~10 minutes), the server releases the lock, drops the handle and socket, and
exits (§4). Any connected client, request, or in-flight operation counts as
activity and holds the daemon alive. Shutdown — requested, idle, or on process
exit/interrupt — MUST remove the handle file, remove the POSIX socket, and
release the lock, so no discovery or write-authority state leaks.

### 17.7 Write-authority lock

Exactly one process may write a workspace's files (working copy, cache, published
snapshot) at a time. The **write-authority lock** is that single-writer token: a
per-folder lockfile acquired with the same `O_EXCL`-create + mtime-heartbeat
primitive as the build-dir lock (§16.6) — atomic across processes, with a crashed
holder's lock going stale and being reclaimed after the heartbeat window — but a
**distinct** lockfile, never the build-dir lock's per-directory naming. The daemon
holds it for its lifetime, making it the sole writer. A client enters the
file-writing fallback lane (§17.4/§4) only after it acquires this lock **itself**,
never on a bare socket error, so two writers can never race. The lock
(write-authority) and the handle file (discovery, §17.2) are separate concerns
with separate files.

### 17.8 Owner-restricted pipe

The daemon's IPC endpoint is a **trust boundary**: any local peer that can open it
can issue mutation and build commands (and, in a later phase, cause daemon-hosted
plugin code to run), i.e. code execution as the daemon's owner. The endpoint
MUST therefore be owner-restricted. On POSIX this is a Unix-domain socket inside a
per-user directory created `0700`, so only the owner can traverse to it; on
Windows it is a named pipe reachable, by its default security descriptor, only by
the creating user. A stronger peer-credential check (`SO_PEERCRED` / `getpeereid`,
or a tightened named-pipe DACL) is a further hardening where the host runtime
exposes it. The endpoint address is derived from the workspace root so it is
stable and unique per folder; clients never recompute it — they read the bound
address from the handle file (§17.2).

### 17.9 Model snapshot and the projection client

The daemon is **model-authoritative**; a client keeps a local **projection** of
the model, hydrated from the daemon and used for rendering and integration (reads
run locally on the projection, only sync crosses the wire).

**One deserializer, two sources.** The client rebuilds its projection with the
SAME deserializer the on-disk loader uses — the source is the wire instead of the
disk. To make that possible the daemon serializes its authoritative model to the
three file-shaped tables the deserializer consumes — the shared baseline, the
working copy, and the cache — plus the **resolved toolchain detection** results,
so the client does not re-detect. The client installs the shipped toolchains and
runs the same merge/deserialize path, producing an identical model. The daemon
owns the disk-reading half (project-source introspection and toolchain
detection); the client's deserialize step is disk-free with respect to the
workspace files. Serializing the daemon's model and re-serializing the client's
projection MUST yield identical results for the same inputs (the parity property,
§17.11).

The daemon and its clients are **co-located on one host**, so the client reads the
project sources locally and identically — those are the project, not the workspace
files, and only toolchain detection (machine-scoped and expensive) crosses the
wire.

**Snapshot request and cold-start.** A client obtains a scope snapshot by request;
the reply carries the snapshot together with the **seq** at which it was taken and
the **session generation**. The handshake `welcome` also carries the seq
watermark and an always-warm **header** (active profile, workspace name, error
state) — bounded and cheap, so a winbar redraw needs no per-frame query (§3.5).
When the session generation changes (a daemon restart), the client discards its
projection and re-hydrates.
