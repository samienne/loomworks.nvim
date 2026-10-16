# Workspace protocol

This document specifies the wire protocol between a workspace **server** and
its **clients**: how a connection is made and authenticated, how messages are
framed and routed, how objects, interfaces, signals and tasks behave on the
wire, and how the protocol and its interfaces evolve. It is written so that a
second, independent server or client can be built from it.

It does not define what any interface *does*: the methods, signals and
records of the interface suite a server offers are specified by that suite
(for loomworks, its interface documents under [`interfaces/`](interfaces/)).
It also does not prescribe how a server or client is built, how a server is
started, found or stopped, or what it runs.

**Normative sources.** The JSON documents in this directory are normative for
**shape**: [`transport.json`](transport.json) for the transport frames and
error codes, `interfaces/<namespace>/<Rest>.<v>.json` for each interface
version, [`meta/`](meta/) for the meta-schemas those documents follow. This
document is normative for **meaning**. Where the two disagree on a shape, the
schema wins; where a schema is silent, this document governs.

Section numbers in this file are local to it (§1, §2, …).

## 1. Terms

- **Server** — the process that serves a workspace's objects. One server
  serves any number of connections at once.
- **Client** — a process that connects to a server and calls it.
- **Connection** — one authenticated byte stream between one client and a
  server. All per-client state of a server is per connection (§9.3).
- **Object** — a path (`/`, `/tasks`, …) naming a **service** the server
  offers. Objects never name entities (§9).
- **Interface** — a named, individually versioned contract — a set of
  methods, signals and error codes described by one schema document per
  version (§9, §16). An object implements one or more interfaces.
- **Entity** — a domain record that travels as plain data, identified by an
  opaque id (§12).
- **Task** — a long-running method invocation whose progress travels on the
  task stream (§14).
- **Session generation** — an integer a server announces in its handshake;
  it changes whenever the server restarts, and scopes every opaque id (§12).

Wire identifiers such as `lw_version`, the `loomworks.*` and `lw.internal.*`
namespaces and `loomworks.Root/1` are historical names, kept as they are.

## 2. Layers

The protocol has three layers:

1. **Transport** — framing (§4), authentication and the handshake (§5, §6),
   the message envelope (§8), the task stream with its flow control (§14) and
   the root object (§10). Only this layer carries the `protocol` number (§6).
2. **Interfaces** — named, individually versioned contracts, each a set of
   methods, signals and errors described by a schema (§9, §16). One server
   may serve several versions of an interface at once.
3. **Data** — entities travel as plain records carrying their opaque `id`
   (§12) and, for display, their `key` / `label`. There are no remote object
   references: the only per-connection state in a server is the connection's
   subscriptions and the tasks it owns, both dropped when it closes.

## 3. Transport bindings

The protocol runs over a reliable, ordered byte stream. A connection to a
server is a trust boundary — a peer that can call the server can make it act
as its owner — so a binding must be restricted by the operating system to the
owning user **and** gated by authentication (§5), except for the private
bindings below.

- **Local stream endpoint** (authenticated). A Unix-domain socket on POSIX or
  a named pipe on Windows, accessible only to the owning user. The connection
  runs the full handshake of §5.
- **Private channels** (unauthenticated). A channel that never leaves the
  process that holds both ends, or the standard input/output of a server
  process the client itself spawned (its connection is a child of the process
  that spawned it), is private and skips authentication:
  - over an in-process channel the connection starts in the authenticated
    state: the server sends `welcome` and nothing before it;
  - over standard I/O the server answers the client's `hello` directly with
    `welcome` — no `challenge`, no `auth`, the nonce ignored. The versions in
    `hello` are negotiated as on the socket (§6), and anything other than
    `hello` first closes the connection. Closing the server's standard input
    ends that connection (§14.5).

  After that, a private connection is served exactly as an authenticated one:
  the same frame limits, calls, replies, task streams, signals and flow
  control. Closing either end is end-of-stream to the other.

How a client finds a server's endpoint, how the endpoint is named, which
access-control mechanism restricts it and when a server is started or stops
are outside this document.

An intermediary (a relay) may sit between a client and a server and forward
frames. To its client it may present the private standard-I/O handshake while
it runs the authenticated handshake with the server itself; it may add
optional fields to the `welcome` it forwards (§7). How a relay behaves is
outside this document.

## 4. Framing

A message (a **frame**) is a JSON object prefixed by its decimal byte length
and a newline:

```
<len>\n<json>
```

Every request carries a `req_id` that its reply echoes; signals and task
frames carry none. An unknown kind, a malformed frame or a handler error
yields a typed error reply (§11), never a crash of the server.

Before `welcome` (§5) a server caps a frame at 64 KiB: a longer length prefix
closes the connection before the payload is read.

## 5. Handshake and authentication

Authentication is mutual and happens before anything else. Let *K* be a
secret shared by server and client and *E* the endpoint address the client
connects to; both are obtained out of band (how is outside this document).

1. client → `hello { protocol, protocol_min?, lw_version, schemas, client,
   role?, nonce = Nc }`
2. server → `challenge { protocol, protocol_min?, lw_version, schemas,
   session_generation, server_nonce = Ns, server_proof }` with
   `server_proof = HMAC(K, "server\n" .. E .. "\n" .. Nc .. "\n" .. Ns)`
3. The client verifies `server_proof`. On failure it closes the connection
   without sending anything else and treats the endpoint as untrusted.
   Otherwise → `auth { client_proof }` with
   `client_proof = HMAC(K, "client\n" .. E .. "\n" .. Ns .. "\n" .. Nc)`
4. The server verifies `client_proof` → `welcome` (§7).

Nonces are 32 random bytes, hex-encoded. Proofs are compared in constant
time. A failed proof closes the connection with no detail. Because the server
proves knowledge of *K* first, a process squatting the endpoint cannot
impersonate the server to a client.

Before `welcome` a server accepts only `hello` and `auth`, applies the frame
cap of §4, closes a connection that has not authenticated within about 5 s,
and sends it no signal.

**Handshake fields.**

- `protocol`, `protocol_min` — the sender's transport range (§6).
- `lw_version` — the sender's implementation version, a string. Clients use
  it for their own policies and for `same_build` interfaces (§9.4); the
  transport does not compare it.
- `schemas` — the versions of the state files the sender reads and writes,
  an object (`transport.json` `FileSchemas`). The transport does not compare
  it; it is carried for client policy.
- `client` — the client's kind, one of the values `transport.json` lists.
- `role` — optional; `observer` marks a client that only watches. A server of
  an older protocol ignores it.
- `session_generation` — the server's session generation (§12).

## 6. Transport version negotiation

`protocol` versions the **transport only**: the framing, authentication, the
handshake, the message envelope (`call`, `ok`, `error`, `signal`, `task`),
flow control and the root object. Everything a client does beyond that is an
**interface** (§9) with its own version, chosen per call; a new operation,
field or view never changes `protocol`. The number moves only for a genuinely
breaking transport change.

`hello` and `challenge` each state a range `[protocol_min, protocol]`
(`protocol_min` absent: equal to `protocol`). Client and server agree on the
highest transport version in the overlap of the two ranges; with no overlap
the server is incompatible with that client. Interfaces are not negotiated in
the handshake: the client chooses a version per interface and stamps it on
each call (§9.4). There are no capability flags.

The current transport is 11; a server of transport 11 also accepts clients of
10 through the aliases of Annex A, until its `protocol_min` is raised to 11.

## 7. The frozen control subset

Framing, `hello` / `challenge` / `auth` / `welcome`, and the control requests
`ping`, `status`, `stop` and `retire` never change shape across versions, so
any two versions can always authenticate, inspect and retire each other.
Fields of these messages are only ever added, never removed, renamed or
retyped, and a receiver ignores a field it does not know.

From transport 11 the frozen subset also covers the `retiring` signal, the
envelope kinds and their routing fields (`kind`, `req_id`, `object`, `iface`,
`v`, `method`, `sub_id`, `task_id`), the transport error codes (§11; new codes
may be added, a client treats an unknown one as `internal`) and the root
interface `loomworks.Root/1` (§10), so any two versions sharing a transport
can also discover each other.

**Control requests.** `ping` is answered with an empty `ok`; `status` with the
server's state; `stop` asks the server to exit; `retire` asks it to accept no
new operations, finish the running ones and exit once idle. The meaning of
`status` fields, and of "busy" and "idle", is defined by the server's
specification, not by the transport.

**`welcome`.** `welcome { header, seq, clients, busy, retiring, objects? }`:

- `header` — an object; `transport.json` names its required fields (`root`,
  `pid`, `lw_version`, `session_generation`). Fields are only ever added — a
  later field never replaces `root`, `pid`, `lw_version` or
  `session_generation`. The interface suite defines the meaning of all header
  fields, and of `seq`, `clients` and `busy`; the header's shape stays in
  `transport.json` (§12.2 says what a client does when `session_generation`
  changes).
- `retiring` — true when the server is retiring (§10.2).
- `objects` — from transport 11: the `describe().objects` list (§10) without
  digests, so a client with nothing else to ask needs no extra round trip.

An intermediary (§3) may add optional fields to `welcome` (it changes no
existing field and does not move `protocol`); a client ignores fields it does
not know.

## 8. Message envelope

After `welcome`, besides the frozen control subset (§7), which stays as it
is, every frame is one of:

```
call   { kind = "call",   req_id, object, iface, v, method, args, env? }
ok     { kind = "ok",     req_id, result }
error  { kind = "error",  req_id, error = { code, message, data? } }
signal { kind = "signal", object, iface, v, name, sub_id?, seq?, args }
task   { kind = "task",   task_id, phase, ... }
```

- `call` invokes `method` of interface `iface` at version `v` on `object`.
  Its reply is exactly one `ok` or `error` with the same `req_id`.
- `ok` carries the method's `result`.
- `error` means the call could not be processed (§11).
- `signal` is an interface signal (§13).
- `task` is a task-stream frame (§14).

`args` are validated against the method's schema before the method runs; an
invalid call is `invalid_args` naming the first violation. A server may also
check its results and signals against their schemas (§11.3, §16.4).

**`env`.** The client's environment, a map of string to string. It is an
envelope field because a method that depends on the client's environment runs
in it; a method's schema declares whether it needs one (`needs_env`, §16),
and a client sends `env` on a call whose method sets `needs_env`.
What a method does with it is defined by the method.

## 9. Objects, interfaces and naming

### 9.1 Interface names

An interface is `<namespace>.<Name>` with a positive integer version, written
`<namespace>.<Name>/<v>`; on the wire `iface = "<namespace>.<Name>"` and
`v = <v>`. Reserved namespaces:

- `loomworks.*` — the core interface suite;
- `lw.internal.*` — same-build facilities that are never a stable contract.

Any other namespace belongs to one extension (a module), named by its id; a
server refuses to mount an extension's interface outside the extension's own
namespace, so two extensions cannot collide.

### 9.2 Objects

Objects are paths naming **services, never entities**. `/` is always the root
object (§10). Which other paths exist is defined by the interface suite and
discovered at run time (§10).

### 9.3 Per-connection state

A server keeps per connection only the connection's subscriptions (§13) and
the tasks it owns (§14). Both are dropped when the connection closes. There
are no remote object references, proxies or lifetimes.

### 9.4 Version choice

For each interface it uses, a client takes the highest version it supports
among the object's offered `versions`, and stamps that version on **every
call and every subscription**; the server keeps no per-connection version
state, so a reconnect only re-runs discovery. With no common version the
client degrades the feature that needs the interface, never the connection.

An interface flagged `same_build` is callable only when the client's
`hello.lw_version` equals the server's; otherwise the call fails with
`same_build_required`.

### 9.5 Case

Methods, signals and error codes are `snake_case`. An extension's own error
codes are prefixed with its namespace (`<id>.<code>`).

## 10. The root object

Object `/` always implements `loomworks.Root/1`
([`interfaces/loomworks/Root.1.json`](interfaces/loomworks/Root.1.json)),
which is frozen (§7): it is never versioned past 1, gaining only optional
fields and new methods, which a client calls only after seeing them in
`describe().root_methods`.

### 10.1 Methods

- `describe {}` — the server's implementation (`binary`), its transport range
  (`transport { min, max }`), its `session_generation`, its `objects` — per
  object its `path`, `owner` and `interfaces`, each `{ name, versions,
  deprecated?, internal?, same_build?, schema_digest }`, where
  `schema_digest` maps a version to the sha256 of its schema document — its
  `root_methods`, and `delivery?`: `"subscription"` when the server sends a
  transport-11 connection task frames and changes only through its
  subscriptions; absent means it also sends the transport-10 broadcasts of
  Annex A.
- `schema { iface, v }` — that interface version's schema document.
- `subscribe { object, iface, v, signals?, args? }` → `{ sub_id, seq,
  initial? }` (§13).
- `unsubscribe { sub_id }` → `{}`; an unknown `sub_id` is not an error.

### 10.2 Root signals

The root's signals reach every authenticated connection without a
subscription:

- `objects_changed { added, removed }` — object paths that appeared or
  disappeared.
- `retiring` — the server was retired (§7): it accepts no new operation and
  exits once idle. `welcome.retiring` carries the same for a connection made
  later.

A server whose objects depend on state it has not loaded yet lists, in
`welcome.objects` and `describe`, only the objects that need none, and sends
`objects_changed` when it loads.

## 11. Errors

### 11.1 Meaning of `error`

`error` means only that the call could not be processed. Outcomes of an
operation the method did process — whether it was accepted, refused or
declined, or needs confirmation — are **method results** inside `result`,
defined by the interface, never transport errors. A stale reference (a removed
entity, an id of an earlier session generation, §12) is the method's own
not-found or refused result, never a transport error.

### 11.2 Transport error codes

`transport.json` lists the codes and their `data`:

| Code | Meaning |
|--|--|
| `unknown_object` | No object at that path. |
| `unknown_interface` | The object does not implement that interface. |
| `unsupported_version` | The interface is not served at that version; `data.versions` lists the offered ones. |
| `unknown_method` | The interface version has no such method. |
| `invalid_args` | The call's `args` (or its envelope) do not match the method's schema; the message names the first violation. |
| `same_build_required` | The interface is `same_build` and the client's `lw_version` is not the server's (§9.4). |
| `not_loaded` | The method needs state the server failed to load; `data` is defined by the interface suite. |
| `stopping` | The server is stopping. |
| `retiring` | The server is retiring and accepts no new operation from this client. |
| `forbidden` | Not allowed for this connection (e.g. cancelling another connection's task, §14.6). |
| `internal` | The call failed inside the server. |

New codes may be added (§7); a client treats an unknown code as `internal`.
An interface declares its own codes in its schema (§16.1).

### 11.3 Replies of mutating methods

Once a mutating method (`mutates`, §16) has run, its reply is never turned
into an error: a server that checks the reply against its schema and finds a
mismatch still sends it as it is, because it may report something that
already started (an accepted task), and an error would let a client run the
operation a second time. A server that checks a non-mutating method's reply
may answer an invalid one with `internal`.

## 12. Identity: ids, session generation and seq

### 12.1 Opaque ids

Ids are the only entity handles on the wire. An entity id is an opaque string
that a client only compares and sends back. Within a session generation an id
is assigned once, follows its entity (not its key) and is never reused; ids
are discarded when the server restarts. An id carries the session generation,
so an id cached from an earlier session never names an entity of this one: it
is a stale reference (§11.1), never resolved to whatever entity the new
session numbered alike.

A `task_id` (§14) and a `sub_id` (§13) are opaque strings scoped to the
session generation in the same way.

### 12.2 Session generation

The server announces its `session_generation` in `challenge`, in `welcome`'s
header and in `describe()`. Ids of an earlier generation are stale (§12.1),
and a new generation forces a full re-fetch of the client's state (§12.3,
§13).

### 12.3 Signal sequence numbers

An interface signal's `seq` counts per object **and connection**, over only
the signals actually sent to that connection: it is gapless for that
connection, so a gap means a lost signal and the client fetches the state
again. `seq` is counted per connection and per object, not per subscription,
so a client with several subscriptions on one object sees gaps in each and
must check gaps across all of them together. `subscribe` returns the
baseline: the last `seq` of that object sent to this connection (0: none), so
the subscription's first signal is `seq + 1`.

## 13. Signals and subscriptions

`Root.subscribe` registers a subscription of the calling connection to one
interface version of one object, optionally limited to some of its `signals`
and filtered by `args` as the interface defines (valid against the
interface's `subscribe_args`; an interface without one takes no `args`). The
server encodes that interface's signals at the subscribed version and stamps
them with the `sub_id`.

An interface declares per signal whether subscribing returns its full state
as `initial`, so subscribing after a reconnect re-hydrates the client.

A connection receives only the signals it subscribed to, plus the root's
(§10.2). After `unsubscribe` it receives none for that subscription.

`seq` and `session_generation` follow §12: a gap or a new generation means
"get the state again".

## 14. Tasks

### 14.1 Task-streamed methods

A method its schema declares task-streamed (the method's `task` entry, §16)
replies `accepted` with a `task_id` — a method result (§11.1) — and then
streams `task` frames for that task. The frames are not interface
signals: ownership, back-pressure, observer bounds and
disconnect-cancellation are transport mechanisms shared by every such method
of every interface. The interface types the task's `meta` and its
`done.result`.

### 14.2 Task frames

Each frame is `task { task_id, phase, ... }`, with `phase` one of:

- `start` — first; carries `meta`. For an interface method's task the meta
  also names the `object`, `iface`, `v` and `method` that started it; its
  other fields are typed by the method's task meta schema.
- `line` — one of the server's own text lines (a status line, a note).
- `output` — a step's raw output bytes, `stdout` or `stderr`.
- `progress` — coalesced: a tick only when the integer percent advances.
- `done` — last; carries `exit_code`, the refusal or failure when there is
  one, and, for an interface method's task, `result`, validated against the method's task result schema.

A task's frames arrive in order: `start` first, nothing after `done`.

### 14.3 Ownership

The connection whose call started a task is its **owner**; every other
connection only observes it. A task belongs to its owner connection: when
that connection closes, for any reason, the server cancels the task (§14.5).
Closing an observer never stops a task.

### 14.4 Flow control and observers

The owner receives every frame of its task, unbounded and in order. The
stream is **flow-controlled**: when about 4 MiB wait unread on the owner's
connection, the task's output window closes. While it is closed the server
sends no further output for that task until the owner has caught up and the
window reopens, and the task's work may be held back meanwhile; the server's
memory stays bounded. Up to that bound the output is buffered, so a reader
paused briefly does not hold the task back, and a task whose whole output
fits completes while the reader waits; the reader still gets all of it, in
order. Cancellation still applies while the window is closed.

Observers receive a task's frames by subscription (§14.6) with output
bounded per task by bytes (a few megabytes each, then a single truncation
notice). An observer whose connection falls further behind than a bound is
disconnected (it connects again to re-attach) — unless it owns a running task
itself, which then only misses observed frames. Only task output is bounded
this way; interface signals are not subject to these bounds.

A connection that owns a running task is never dropped for silence.

### 14.5 Cancellation

A task ends early when its owner cancels it (§14.6), when its owner's
connection closes, or when the server can no longer carry it (it stops, or
what the task operates on goes away). The server then stops the task's work,
releases what it holds and ends the task with a `done` with a nonzero `exit_code`.

A client that loses the connection after its task was accepted reports a
failure; it never re-runs the operation another way.

### 14.6 Observation, listing and cancel

The interface suite provides one task interface on one object (in the
loomworks suite `loomworks.Tasks/1` on `/tasks`) with:

- **observation by subscription** — a connection subscribed to it
  (optionally for one `task_id`) receives its started / ended signals and the
  frames of the tasks it matches, bounded as for an observer (§14.4);
- **listing** of the running tasks;
- **cancel `{ task_id }`**, allowed for the task's owner only; any other
  connection gets the error `forbidden`.

A connection that joins late — subscribing with a `task_id`, or adopting what
the listing returns — receives a task's frames from that moment; nothing
earlier is replayed.

### 14.7 Steps

A task may announce its **steps**: its listing entry and its `start.meta`
carry `steps`, one record per step in run order, each with an opaque `id`
stable within the task, a `kind`, a `label` and a `state`, every step in
the initial state at start. Each transition is a `step { task_id, seq, index, state,
error? }` signal of the task interface, its `seq` the signal envelope's `seq`
(§12.3); a task's `step` signals follow its started signal and precede its
`done`. `step` is a delta on top of the announced steps: on a `seq` gap a
client re-reads the listing. Clients show an unknown step kind or state as
neutral. The step kinds and states, including the initial state, are defined by
the interface suite.

## 15. Delivery guarantees

This section collects the guarantees stated elsewhere in this document.

- A reply echoes its call's `req_id` (§4, §8).
- A task's frames are in order (§14.2); the owner gets all of them (§14.4).
- Only an observer's task output may be dropped, with a truncation notice, or
  the observer disconnected (§14.4); interface signals are not subject to
  these bounds.
- A `seq` gap means a lost signal, and a new session generation a new
  server: in both cases the client fetches the state again (§12).
- After a reconnect a client re-runs discovery (`welcome.objects` or
  `describe`), re-subscribes, and treats a new session generation as §12.2
  says. Task output earlier than the moment of (re)joining is not replayed
  (§14.6).

## 16. Schemas

### 16.1 Interface documents

Each interface version has one schema document,
`interfaces/<namespace>/<Rest>.<v>.json` (`loomworks.Root/1` →
`interfaces/loomworks/Root.1.json`), valid against
[`meta/interface.schema.json`](meta/interface.schema.json). It is JSON Schema
(2020-12) for parameters, results, signal payloads and shared definitions, in
an envelope naming the interface, version and status and, per method:

- `params` and `result`;
- `task` — present for a task-streamed method: the task's `meta` and its
  `done` `result` (§14);
- `errors` — the codes the method may return besides the transport's;
- `needs_env` — whether the method needs the client environment (§8);
- `mutates` — whether the method changes state (§11.3);

per signal its `args` and whether subscribing returns `initial` (§13); and per
interface the schema of a subscription's `args` (`subscribe_args`), the
interface's own error codes, and the flags `frozen`, `same_build`, `internal`
and `types_only` (shared definitions only, mounted on no object).

The transport frames and error codes are described the same way in
[`transport.json`](transport.json), valid against
[`meta/transport.schema.json`](meta/transport.schema.json).

### 16.2 Restricted keyword set

Documents use only these keywords, which every validator implements
identically: `type`, `properties`, `required`, `additionalProperties`,
`items`, `enum`, `const`, `oneOf`, `$ref`, `$defs`, `minimum`, `maximum`,
`minItems`, `pattern`, `description`.

### 16.3 Digest

`schema_digest` (§10.1) is the sha256 of the schema document, as lowercase
hexadecimal.

### 16.4 Validation

A server always validates a call's `args` (§8). Whether it also checks its
results and signals is up to the implementation (§11.3); a result or signal
that does not match its schema is a defect of the server.

### 16.5 Where documents live

The core suite's documents, the transport document, the golden transcripts
(§18) and the frozen snapshot of every released interface version
(`frozen/`, §17.1) live in this directory. An extension's documents live
with the extension.

## 17. Evolution and compatibility

### 17.1 Within a version

Within an interface version only additive changes are allowed. Against its
frozen snapshot, a version's **parameters** (method `params`,
`subscribe_args`, and the transport frames a client sends) may only gain
optional properties and enum values; its **results and signals** may only
gain properties, enum values and alternatives. Nothing is removed (including
an enum value), renamed, retyped or made required. Anything else is a new
version.

A client that sends a parameter value added after the version first shipped
checks the interface's `schema_digest` (or the server's version) first, since
an older server refuses it as `invalid_args`.

### 17.2 Tolerance

Clients **must tolerate** unknown fields, unknown enum values and unknown
alternatives in results and signals (an unknown value is shown as unknown or
neutral, never a failure), so an interface may add a field, a state or an
outcome without a new version. Receivers of the frozen control subset ignore
unknown fields (§7).

### 17.3 New versions and deprecation

A breaking change makes version `N+1`. A server keeps accepting the previous
version `N` for a support window that the interface suite's release policy
defines, and announces `N` in `describe()`'s `deprecated` meanwhile. A
transport version below a raised `protocol_min` is retired under the same
policy.

### 17.4 Conformance checks

The contract is enforced by:

- a **lint**: every document is valid against its meta-schema and uses only
  the allowed keywords (§16.2);
- an **additive ratchet** (§17.1) against the frozen snapshot;
- **server conformance**: golden transcripts (§18), driven against any server
  over the standard-I/O binding (§3);
- **client conformance**: a client against the same transcripts, replayed,
  for every interface version it claims.

## 18. Transcripts

A transcript file, `transcripts/<namespace>/<Rest>.<v>.json` beside the
interface's schema and valid against
[`meta/transcript.schema.json`](meta/transcript.schema.json), is
`{ transcripts = 1, interface, version, description, cases }`.

**Cases.** A case (`name`, `description?`, `fixture?`, `hello?`,
`handshake?`, `allow?`, `steps`) runs on a fresh server over one connection,
on a workspace the runner prepares (`fixture`; the fixtures are defined by the
interface suite, the default being an empty workspace). Unless `handshake` is
false the runner sends `hello` (the case's `hello` fields over the default)
and binds the `welcome` as the variable `welcome`; `lw_version`, `env` (the
client environment to send) and `root` are bound before.

**Steps.** A step is

- `send` — a frame template, validated against the transport unless
  `malformed`;
- `expect` — the earliest unconsumed received frame its selector picks must
  match the pattern, within `timeout_ms`. The selector is `kind` and the
  literal `req_id`, `object`, `iface`, `name`, `sub_id`, `task_id` and
  `phase`;
- `expect_none` — no frame the selector picks arrives `within_ms`.

Frames of other streams interleave freely, and at the end every received
frame must have been consumed or match an `allow` pattern.

**Patterns.** Patterns are partial: an object names the fields it checks, an
array has the actual length. An object whose keys all start with `$` is a
matcher: `$any`, `$type`, `$absent`, `$bind` (bind or compare a variable),
`$var` (a bound value, with `$with` merged over it in a template),
`$contains`, `$exact`, `$pattern`, `$len`, combinable. An explicit `null` is a
present value (`$absent` fails on it, `$any` accepts it), and an object
pattern never matches an array nor an array pattern an object.

**Runner checks.** The runner validates every received frame:

- transport frames against the transport document;
- an interface call's `ok` against its result schema, and its `error` code
  against the transport's and the method's codes;
- a signal against its schema, with a gapless `seq` per object, none for a
  subscription after its `unsubscribe`, and its `session_generation` (if any)
  the `welcome`'s;
- every task's frames in order (`start` first, nothing after `done`; integer
  ids at transport 10, strings from 11), and the task frames of a
  task-streamed call (the start meta naming the method; `done.result` against
  its task result schema);
- a transport-10 reply against its v0 shape (`transport.json` `v0.replies`),
  so the v0 aliases provably stay unchanged; other transport-10 frames are
  only matched.

## Annex A (informative): transport 10 and the v0 aliases

Transport 10 predates the envelope. A server of transport 11 accepts clients
of 10 and serves them as follows until its `protocol_min` is raised to 11,
after which this annex no longer applies.

- **Request kinds.** The transport-10 request kinds (`build`, `test`,
  `prepare_run`, `clean`, `reset`, `snapshot`, `query`) are served unchanged
  as **v0 aliases** of the corresponding interface methods, with the same
  effect as calling them. A v0 request gets a v0 reply, whose shape
  `transport.json` `v0.replies` keeps (the operations' outcome flat on the
  reply); a v0 `error` reply carries `error` as a string. Only an interface
  call gets the structured `error` object (§8).
- **Broadcasts.** A transport-10 connection receives, unconditionally and
  without subscribing, every task's frames and the `model_change { seq,
  session_generation }` broadcast. That broadcast's `seq` advances by one per
  broadcast per server session; a broadcast at or below the last `seq` of the
  same session generation is ignored, a new generation is always applied.
- **Task ids.** A transport-10 connection keeps integer task ids in its task
  frames, its accepted replies and `status.tasks`.

## Annex B (reserved): providers

A server may host extensions **out of process**: a provider is spawned by
the server (`<provider> --stdio`) or connects with `hello.role = "provider"`,
and registers its objects and their schemas through
`loomworks.Provider/1.register`. The server routes calls for the provider's
objects to it and forwards its signals and task frames; the task stays owned
by the calling client connection, the provider only produces its frames. The
core's extension contract for such a provider is the interface
`loomworks.ModuleProvider/1`, which the server calls. The role, these two
interface names and the routing rule are reserved; nothing else of providers
is specified until they are built.
