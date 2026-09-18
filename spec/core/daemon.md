> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.
>
> This file is written **per-phase** as the daemon line lands (see
> [`../../DAEMON.md`](../../DAEMON.md), the design overview, and its §8 promotion
> ladder). It currently specifies only the **Phase-0 / rung-1** surface —
> runtime-mode resolution, the daemon handle file, wire-protocol versioning, the
> daemon **client stub**, and the runtime broker. The daemon *server*, the
> projection client, commands, and broadcasts (DAEMON.md §2–§4) are later phases
> and are NOT specified here yet.

## 17. Daemon Runtime (Phase 0: awareness without capability)

The system runs its workspace either **in-process** — the editor or CLI process
*is* the workspace, as in §1–§16 — or, in a later phase, by driving a long-lived
**daemon** that owns the model, files, and execution. Phase 0 establishes the
mainline foundations for the latter **without shipping a daemon server**: a
runtime-mode flag, a discovery handle, a versioned wire protocol, a broker that
resolves which runtime *would* be driven, and a client that can **detect and
stop** a daemon it finds. This is daemon *awareness*, not daemon *capability*.

**In-process is the permanent default and fallback.** Every contract in §1–§16
holds unchanged in Phase 0: with no daemon server present, resolving any runtime
mode still executes in-process. Nothing here may regress the in-process path.

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
daemon record rather than an error.

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
the broker chooses what runtime a daemon would be *driven from*. In Phase 0 the
broker **resolves only** — it never spawns — because there is no daemon server on
mainline to drive; driving a resolved runtime is a later phase.
