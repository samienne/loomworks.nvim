# Loomworks interfaces

This document specifies the **loomworks interface suite**: the objects a
loomworks server offers over the [workspace protocol](PROTOCOL.md), and for
each of its interfaces the meaning of its methods, results, signals and
errors. Together with PROTOCOL.md it is meant to be enough to build a second,
independent server or client of the suite.

It does not repeat the protocol: connections, the handshake, the envelope,
subscriptions, `seq`, session generations, the task stream, schemas and
versioning are PROTOCOL.md's. It does not prescribe how a server is built,
started or found, nor what a client does with what it reads.

**Normative sources.** The interface documents under
[`interfaces/`](interfaces/) are normative for **shape** — methods, their
parameters and results, signals, types, required and optional fields, enums,
`needs_env`, `mutates`, and each task-streamed method's task meta and result.
This document is normative for **meaning** and does not restate the types;
where a document and this text disagree on a shape, the document wins. Only
interface versions that have a document are specified here; the server's
roadmap of further interfaces is not part of the contract.

**Section numbers.** `§n` is a section of this document. `spec §n` is a
section of the loomworks behavioural specification
([specification.md](../../specification.md) and its topic files under
[`spec/core/`](../core/)), which defines the workspace model, its files and
the CLI's commands the operations below perform. `PROTOCOL.md §n` is a
section of the protocol.

**The CLI's behaviour.** Many operations below are the CLI's commands run by
a server. Where this document says an operation prints, refuses or fails *as
the CLI does* (its lines, messages and exit codes), it means what the
behavioural specification gives for the same command run by the CLI on its
own (spec §16).

## 1. Conventions

### 1.1 Entities and records

The data layer's entities are profiles, configuration sets, projects,
configurations, launch configurations, configuration units, SDKs, tasks,
devices and build directories, each with its opaque `id` (PROTOCOL.md §12.1)
and its `key` / `label`. Ids are the only entity handles on the wire. Every
entity record in an interface result or signal carries its `id` and its
`key` / `label` for display. A project's variables, deploy destinations and
`type_config` fields, and a toolchain's key, are not entities: they are
values of their owner (§1.2).

### 1.2 References

A request names an entity by a reference (`loomworks.Common/1` `Ref`),
either `{ id }` or `{ key }`. A client may send an id taken from a result or
view, or a key; the server resolves a key as spec §16.9 specifies (its
messages and exit codes). Keys are the model's
keys (spec §1). Each method states how it answers a reference that does not
resolve (§8.3, §10.2, §11, §6, §19–§22). An id resolves to its entity
itself, never through the entity's key: an entity renamed since the id was
issued is still the one named. An id issued before the server loaded the
workspace again (a trust change, the removal of the working copy, a newer
schema) or before a restart is stale; a command answers it `refused`, `no
<kind> with id <id> (a stale reference)`, and changes nothing.

An **item reference** (`ItemRef`) names a profile, configuration set,
project, configuration or launch configuration without saying which: ids
are unique across kinds, so `{ id }` alone resolves. In step 5o an
`ItemRef` is an id only; it has no key form.

A **launch configuration** or a **configuration** is named by a `Ref`: its
id, or with `{ key }` (its name) the request's `project` reference as well.
An id that is not of the request's `project` is `refused`.

A project's **variable**, **deploy destination** or **`type_config`
field** is not an entity: a request names its project by a reference and
the entry by its name, and the command edits that field of the project. A
**toolchain** is named by its key, a value a profile stores (§11).

## 2. Handshake values

PROTOCOL.md §5 and §7 leave these values to the suite:

- `hello.client` is `cli` or `editor`; `role = "observer"` is a client that
  only watches.
- `welcome.header` carries `root`, `pid`, `lw_version` and
  `session_generation`, plus the model's `state`: `loaded` with the
  workspace's `name` and `active_profile` (the active profile's key, absent
  when none); `error` or `refused` (a trust, newer-schema or journal refusal)
  with the load failure's `error` message; or `unloaded` before the server
  loaded the workspace. Sending `welcome` never loads the workspace. The same
  record is `Workspace/1.header` (§6).

## 3. Objects and the root

The core services are `/workspace`, `/profiles`, `/projects`, `/build`,
`/tests`, `/launch`, `/lsp`, `/debug`, `/tasks`, `/toolchains`, `/devices`,
`/maintenance`, `/views`, `/internal`, and `/modules/<id>` for each module
(§17). A module's namespace is its module id.

In `loomworks.Root/1` (PROTOCOL.md §10): `describe().binary` is
`{ lw_version, impl, dev }`; an object's `owner` is `core` or the module id.
The root's `objects_changed` reports a module loaded or the workspace loaded
or unloaded. A server that has not loaded its workspace lists the objects
that need none.

## 4. Common types

`loomworks.Common/1` holds the types every core interface shares; it is
mounted on no object.

### 4.1 Outcomes

The operations' outcomes — `ok`, `accepted`, `refused` (with message and
exit code), `declined` (with reason), `confirm` (with lines and plan) — are
a union every interface shares (`Outcome`). They are method results, never
errors (PROTOCOL.md §11.1):

- `ok` — a read answered, or a command (§6, §11, §12, §13, §19–§21) applied:
  its writes are committed and its `changed` was sent. A command that
  performs one user action in several steps (adding a project and upgrading
  its profiles' toolchain) and could not do a later step after the first
  one was committed is `ok`, with a `warn` note naming what was not done; a
  command is never partly applied without saying so. A created entity comes
  back in the result as `{ id, key }`;
- `accepted` (`task_id`, `profile_key`, `pid`) — for a task-streamed method,
  the operation runs as a task owned by this connection (PROTOCOL.md §14.3);
- `refused` (`message`, `exit_code`) — before any side effect: the workspace
  is refused (spec §17.4, a journal it cannot complete, a newer schema
  spec §2.7) or an argument does not resolve (§1.2). A non-interactive call
  that omits a required operand (the profile) is refused too; `exit_code` is
  the in-process code — 2 for a usage error (§16.7), 1 for a state refusal. A
  client prints the message and ends with that code; with `stream = "out"` the
  message is the command's ordinary standard-output line, not an error;
- `declined` (`reason`) — before any side effect: the server does not carry
  this request; a client may run the operation another way (the CLI runs it
  itself);
- `confirm` (`lines`, `plan`) — the operation needs the user's confirmation
  of a plan first (§8.6).

`ok`, `accepted`, `refused` and `confirm` may carry `notes`: lines the server
wrote for the call before any task of it started (a warning or error the
workspace raised while loading, a test plan's pre-build notes, §10.1), in
order. A client writes each to standard error
before anything else of the call, the refusal's message included. With them
`note_roles` (`NoteRoles`) gives each note its role (`LineRole`, §4.2) by
index: the role the CLI gives that line in-process (a workspace error `fail`,
a warning `warn`, a test plan's note `plain`). A missing `note_roles`, a
missing entry or an unknown role is `plain`; a note's text never contains
terminal escape sequences.

The error `not_loaded` means loading the workspace failed; its `data`
carries the header's `state` and `error` (§2).

### 4.2 Task meta and end

A task-streamed method's `start` frame carries `meta = { name, kind,
profile, profile_id, units, origin }` (`TaskMeta`), besides the `object`, `iface`, `v`
and `method` PROTOCOL.md §14.2 adds:

- `kind` — the operation: `build`, `configure`, `clean`, `reset`, `test`,
  `discover`, `run`, `debug`, `delete`, `nuke` (each method below names its
  own);
- `profile` — the profile's key, and `profile_id` its id (both absent for a
  task scoped to units, §8.3, or to every build directory, §8.5, which
  carries `scope = "all"`);
- `units` — one `{ project, configuration, id }` per project of the profile
  (or of the task's scope): the project key, its configuration unit's key and
  the unit's id (§1.1; absent for a unit the server has no id for). A client
  matches a task to its records by the ids; the keys are for display.
- `origin` — the owner's `hello.client`, `cli` or `editor`, set by the
  server, never taken from the request.

The task's `line` frames are the operation's own lines — a status line on
standard output, a note on standard error. Its `done` carries `exit_code`
and the refusal or failure a client prints as `lw: <error>`; the method's
task result (`TaskEnd` and what the method adds) is in `done.result`.

A `line` frame may carry a `role` (`LineRole`), as a reply's notes may (§4.1):
`lead` (the operation's lead line, e.g. `building profile: <p>`), `phase` (a
step header `==> [<kind>] <name>`), `reason` (a configure reason), `command`
(a command line printed for `verbose`, below), `ok` (a success outcome),
`fail` (a failure), `warn` (a warning) or `plain` (an informative line with no
other role). These are the roles of spec §16.7 *Highlighting*, and the server
gives each line the role the CLI gives it in-process. A line without `role` is
`plain`, and so is a role a client does not know. The `text` never contains
terminal escape sequences: whether and how a role is shown (colour, `--color`,
`NO_COLOR`) is up to the client.

From transport 11 a `task_id` and a `sub_id` are opaque strings
(`TaskId`); a connection of protocol 10 keeps its integer task ids
(PROTOCOL.md Annex A).

### 4.3 Steps of a task

A target-scoped task — `Launch/1.build`, and `prepare_run` /
`prepare_debug` with `build_scope = "target"` (§9) — announces its steps
(PROTOCOL.md §14.7): its `TaskInfo` (the `started` signal, `Tasks/1.list`)
and its task's `start.meta` carry `steps`, one `{ id, kind, label,
project?, configuration?, target?, phase?, state }` per phase in run order
(`id` opaque, stable within the task; `kind` `build` for a dependency's or
the target's own unit, `deploy` for a deploy phase with `phase` `pre_build`
or `post_build`, `probe` for the artifact probe), each `pending` at start. A
preparation with `no_build` has no steps (`steps` absent). Each transition
is a `Tasks/1` `step { task_id, seq, index, state, error? }` signal
(`running`, `ok`, `failed` with its failure line, `cancelled`; `skipped` for
a step a failure, a cancel or a `device = true` outcome left unrun). A unit's
own tool steps (configure, build) are not steps here; they stay its lines,
output and progress. Every step also has its line on the task stream
(`building dependency: <project>`; a deploy phase `deploying (<phase>): <n>
copies`, where `n` counts the phase's declared sources, including fresh ones
the copy will skip; a single source reads `1 copy`). A deploy whose copies
all completed is `ok` even when a cancel arrived during its last copy (its
freshness records are saved); the cancel then stops the task before its next
step.

### 4.4 Launch and debug specs

A `LaunchSpec` is `{ name, cmd, args, cwd, env }` — the resolved command, its
arguments (a command configuration's declared arguments, then `extra`), the
absolute working directory and, in `env`, only the launch's own contribution
over the client's environment (the overrides spec §16.17 "Command
inspection" reports), never a whole environment.

A `DebugSpec` is:

- `name`, `program`, `args`, `cwd`, `env` — resolved exactly as the run's
  launch of the same target and arguments (`program` is the run's `cmd`;
  `env` only the launch's own contribution, the spec §17.9 denylist applied,
  never a whole environment). A run and a debug of one target differ only in
  who starts the program (spec §8.9.6 "Launch target debugging");
- `language` — the launch's primary language: a launch configuration's first
  `debug` entry (spec §8.9.6 "Multi-adapter debugging"), otherwise the
  primary language of the target's module;
- `adapters` — one `{ language, adapter }` per debug language in order (a
  launch configuration's `debug` array, otherwise `language` alone), each
  adapter resolved from the workspace's mapping with its default (§12): the
  first launches the program, the others attach to its process.

### 4.5 Test types

A `TestNodeRef` names a node of `view.Tests/1` by its view `id` (§14.3). A
`TestCaseResult` is `{ id, status, duration?, message? }` (`duration` in
milliseconds, `message` the first failure line). `TestStatus` is `queued`,
`running`, `passed`, `failed`, `skipped`, `errored`; a client shows an
unknown status as neutral.

## 5. Environment

`env` (PROTOCOL.md §8) is an envelope field because every method that
touches the model runs in it. An operation behaves as if the client process
had run it. The client sends its **whole environment**; the server applies
it to the operation and to nothing else:

- every piece of model work for the request (loading or syncing the
  workspace, argument resolution, planning, gates, cache write-back) sees the
  client's environment — so `${VAR}` expansions, tool and program resolution
  on `PATH` and probes a module spawns see the client's values; two requests
  never see each other's environment;
- each step is spawned with exactly the client's environment plus the step's
  own variables (spec §8.1, on Windows replacing a name that differs only in
  case) — never the server's own launch environment.

The whole environment is sent because a subset cannot be chosen safely:
compiler, SDK and `vcvarsall` variables (`INCLUDE`, `LIB`, `WindowsSdkDir`,
`VCToolsInstallDir`, …), cache tools and `${VAR}` references in the
configuration can use any name, and the CLI's own command inherits them all.
It may contain secrets: a server holds it for the request only and never
writes it to the runtime log, the handle or any workspace file. The client's working directory is not
sent: the client resolves the workspace root, and every step runs in its
own absolute directory (the step's, or the root).

## 6. `loomworks.Workspace/1`

On `/workspace`:

- `header {}` — the header of §2. It never loads the workspace.
- Signal `changed { seq, session_generation, scopes? }` — the model changed
  (a committed write of a state file); a client fetches the state it holds
  again. `seq` is the signal's sequence number, counted as PROTOCOL.md §12.3
  specifies; `scopes` names the files that changed (`config`, `user`,
  `cache`) when known. The session generation is PROTOCOL.md §12.2.
- Signal `header_changed { header }` — the header's state, name, active
  profile or load error changed (a load, a reload, a failed load, a write
  that changed the active profile).

*(Step 5o.)* The model's **commands** — here and in §11, §19–§22 — are
mutating methods, each run in a model segment of the client's environment
(§5) against the model as the files hold it (another process's writes taken
in first). A command answers `ok` (§4.1), `refused` or `declined`, and
where it says so `confirm`. It is `refused`, with nothing written and the
model unchanged, when a reference does not resolve or is stale (§1.2), when
the working copy is stale (spec §2.7) or the workspace is not trusted (spec
§17.4; except `trust_accept` and `delete_user_prefs`), when a lock it needs
is held (the refusal names the holder, spec §19.3), or when the write
fails. Its `changed` and the views' `update`s (§14) precede its reply.
Writes go to the working copy (`user.json`) unless a command says
otherwise; a command that writes more than one workspace file, or removes a
workspace file or a build tree, takes the workspace operation lock first
(spec §19.3) — a publish, and a rename that propagates into the cache (a
profile's key derived again included), among them.

- `publish {}` — regenerates `loomworks.json` from the working copy (spec
  §2.4; the status page's `:w`), under the workspace operation lock;
- `publish_one { item }` / `revert_one { item }` — publishes one item, or
  reverts it to the published baseline (spec §2.4);
  `item` an `ItemRef` (§1.2); `publish_one` under the workspace operation
  lock;
- `revert_to_baseline {}` — the working copy's published items back to the
  baseline, locally added items kept as `local` (spec §2.4; `:e!`);
- `set_intent { item, intent }` — the item's intent, `local`, `shared` or
  `local+shared`, recorded as the user's choice (spec §2.4, sticky);
- `set_description { item, text? }` — the item's description (spec §1.10),
  normalized as written there; no `text` removes it. `item` may also name a
  launch configuration.

A launch configuration has no publish state (§14.4): `publish_one`,
`revert_one` and `set_intent` on one are `refused` (`a launch configuration
is published with its project <project key>`, naming the project that owns
it).

- `trust_accept { plan? }` — the review & trust of spec §17.4. Without
  `plan`: `confirm`, `lines` the review a client shows (what the working
  copy holds that needs trust, as `lw trust` lists it) and `plan` a token of
  exactly that content. With `plan`: the working copy is signed as shown, or
  `refused` (`the working copy changed since it was shown — review it
  again`) when its content differs. A working copy that is already trusted
  answers `ok` with a note, not `confirm`; with no working copy (no
  `user.json`) it is `refused`. It is served while the header's state is
  `refused`; the server then loads the workspace again (`header_changed`),
  so every id issued before is stale;
- `delete_user_prefs { plan? }` — removes the working copy (spec §17.10,
  `lw trust --discard`, its `.nvim` path checks), confirmed as
  `trust_accept` is, under the workspace operation lock; the confirmed
  content is checked again under that lock, and a file that changed since is
  `refused` with nothing deleted. With no working copy it is `refused`.
  Also served while the header's state is `refused`; the server then loads
  the workspace again.

*(Deferred, not in step 5o.)* Creating a workspace — writing a new
`loomworks.json` at a root that has none (the status page's `N`) — is not a
method in step 5o: a client creates one with `lw init`. A
`Workspace/1.create { name? }` is deferred until a server serves a root
with no `loomworks.json`.

## 7. `loomworks.Tasks/1`

The task interface of PROTOCOL.md §14.6, on `/tasks`:

- `list {}` — the running tasks (started, not ended), in start order, each a
  `TaskInfo`: its start meta with its `task_id`, `started_at`, last
  `percent`, `owned` (the calling connection owns it), and for a
  target-scoped task its steps with their current states (§4.3).
- `cancel { task_id }` — allowed for the task's owner only (`forbidden`
  otherwise); a task that is not running is the `refused` result.
- Signals `started`, `ended` and `step` (§4.3); a subscription may name one
  `task_id`.

There is no `attach`: a late joiner subscribes with a `task_id` or adopts
what `list` returns, and receives output from then on.

### 7.1 Task-streamed methods

The task-streamed methods are `Build/1.build`, `configure`, `clean` and
`reset`, `Tests/1.run`, `discover`, `run_cases` and `prepare_debug`,
`Launch/1.prepare_run`, `prepare_debug` and `build`,
`Maintenance/1.execute_deletion` and `nuke`, and a module's log stream. Each method's schema types the task's `start.meta` and its
`done.result` (for `prepare_run` the launch spec, for `prepare_debug` the
debug spec, for a test run its structured results: `steps`, one `{ name,
exit_code, status }` per test step run, and the `junit` files written). The
outcomes of the operations (§4.1) are domain results of the method, not
errors.

### 7.2 Cancellation

A task ends early when its owner cancels it, when its owner's connection
closes, when the server stops, or when the workspace or the operation's
subject is unloaded or removed (PROTOCOL.md §14.5). The server then
terminates the running step's process tree, records nothing for that step,
releases the operation's locks and ends the task nonzero, with `build
stopped: <reason>` (`test stopped: <reason>` for a test run; `run stopped:
<reason>` for a run's preparation, `debug stopped: <reason>` for a debug's;
`configure stopped: <reason>` for a configure; `clean stopped: <reason>` for
a clean; `reset stopped: <reason>` for a reset; `delete stopped: <reason>`
for a deletion; `nuke stopped: <reason>` for a nuke). Cancellation ends with the
task: a program a client starts after a preparation (§9) is never the
server's to stop.

## 8. `loomworks.Build/1`

On `/build`: the operations of `lw build`, `lw clean` and `lw reset`, and a
configure. Each is task-streamed and replies with an outcome of §4.1.

### 8.1 Outcomes

`build` replies:

- `accepted` — the build runs as a task owned by this connection;
- `refused` — before any side effect: the workspace is refused or the profile
  argument does not resolve (spec §16.9);
- `declined` — before any side effect, for the interactive onboarding of a
  profile from a configuration set (prompts, spec §16.9) and for a request
  in a different environment while another build runs in it.

`configure`, `clean` and `reset` have the outcomes of `build`, with the
additions below.

### 8.2 `build`

`build { profile?, targets?, extra?, force?, reconfigure?, verbose?, units?,
jobs?, interactive, command }` builds the profile — the parsed command line
of `lw build [<profile>] [--target <name>]… [--force] [--reconfigure] [-v]
[-- <args>]` — or the configuration units of `units` (§8.3). Its task's
`meta.kind` is `build`.

An accepted build performs the shared build-step sequence of spec §16.4 /
§16.6 / §16.28 / §5.1 / §5.10 as the CLI does: the build-directory locks of
spec §16.6 taken up front in canonical order, a dead holder's lock reclaimed
with the interrupted step's state recovered, the build gate, the
artifact-conflict gate (`force`), the full-reconfigure reset
(`reconfigure`), the configure record and the cache write-back under the
save guard (spec §2.7 — a refused save ends the build with its message), the
failure line with the `--target` hint, and `BUILD OK: <profile>`.

- **`jobs`** — an integer ≥ 1: the build tool's parallelism for this build
  only, passed to the module as its parallel-jobs option (`-- -j<jobs>`, or
  `-j<jobs>` right after a `--` the step's arguments already carry).
- **`targets`** — items may be `{ project, target }` besides a string: that
  target of that project only. A string keeps its meaning (`--target`,
  spec §16.4); a bare name in the known target lists of several units of one
  project is that project's, not ambiguous. A project the scope does not
  build ends the task before any step with `target '<t>' names project
  '<p>', which <scope> does not build` (exit 1), as an ambiguous `--target`
  does.
- **`verbose`** (`-v`) — the task also streams, under each step's header and
  on its stream, the command lines of spec §16.4 *Verbose* as `line` frames of
  role `command`. It changes what is streamed, never what runs.

### 8.3 `configure` and unit scopes

**`configure { profile | units, reconfigure, interactive, command }`** —
`meta.kind = configure`. It runs the configure step of every unit of its
scope — also one already configured — with the gates of the build-step
sequence that apply before a configure (the validity and tool/configuration
compatibility gates refuse as the CLI does) and `reconfigure` meaning the
full-reconfigure reset (spec §16.4). The build-directory locks of spec §16.6
are taken **exclusive** up front in canonical order (a dead holder's lock
reclaimed as for a build). It prints `configuring <scope>`, one `==>
[configure] <name>` line and step per unit, and `CONFIGURE OK: <scope>`; a
failing step ends the task with its failure line and the step's exit code,
the later steps not run. It writes the configure record and the cache as a
configure does (spec §16.4), the write-back's `changed` before `done`. It
cancels as a build (`configure stopped: <reason>`).

**`units`** on `build`, `configure` and `clean` — a non-empty array, each
item `{ id }` (a configuration unit's id, e.g. a `view.ProjectsIndex/1`
record's `active.unit_id`) or `{ project, configuration }` (the project key
and configuration-unit key, as in `meta.units`); exclusive with `profile`
by key or by id (both → `invalid_args`; a unit that does not resolve →
`refused`). The scope is then those configuration units, each with the tool
its unit records — the same steps, locks, gates and lines as for a profile,
restricted to them. Such a task's `meta.profile` is absent and `meta.units`
lists the units. `<scope>` in the lines above is `profile: <name>` (as in
`building profile: <name>`) or the units' `<project>/<configuration>` names,
comma-separated, and in the OK lines the profile's name or those names; a
unit's refusal reads `no configuration unit <project>/<configuration>
(unknown project or configuration)`, or for an id the stale-reference
refusal of a profile id. A scope with no configure step to run (a module
without one) prints `nothing to configure for <scope>` and ends 0. A unit
with no tasks at all — no module available, or its tool not detected on this
machine — is not that: the build or configure ends 1 before any step with
`cannot build: <project>/<configuration>: no tasks (unavailable module or
undetected tool)`; a `clean` with such a unit's tool undetected is refused
as a profile's is, never skipping the unit.

### 8.4 `clean`

`clean { profile | units, verbose?, interactive, command }` — `lw clean
[<profile>] [-v]` (spec §16.1: each project's build-system clean on the
profile's build directories; the configuration is kept). `verbose` as for
`build` (§8.2): each clean command and each core-performed wipe
(`    remove <dir>`). It is also `refused`, with the
`nothing to clean for profile '<p>' …` line, its exit code (1) and
`stream = "out"` (§4.1: an ordinary standard-output line, not an error — the
editor reports it as information and a rebuild goes on to its build), when
the profile has no configured build directory on disk to clean or no module
clean for it — decided after resolution and before any lock. Its task's `meta.kind` is `clean`. An
accepted clean does, and prints, what the CLI's clean does: the
build-directory locks of spec §16.6 taken **exclusive** up front in
canonical order (a dead holder's lock reclaimed and its state recovered as
for a build), `cleaning profile: <p>`, one `==> [clean] <name>` line and
step per project, and `CLEAN OK: <profile>`; a failing step ends the task
with its failure line and the step's exit code, the later steps not run.

A **core-performed wipe** (spec §8.1 `wipe_build_dir`) is the build-directory
deletion of spec §4.6 and §4.7: the path is validated first (spec §4.6:
non-empty, within the workspace root and never the root itself, links not
followed, no command interpreter) — a refused path ends the task with the
`clean refused: unsafe build directory …` line; the clean's units sharing the
directory are one deletion batch; the cache says `unknown` on disk before the
tree is removed and the units are reset only after the removal succeeded; a
directory still used by a configuration outside the clean is kept (the
`kept <dir> — still used by another configuration` line). Cancelling during
a wipe stops it between entries (`clean stopped: <reason>`); what was
removed stays removed and the cache stays `unknown` (never reset after a
partial removal, spec §4.7). The clean writes the cache exactly when the
CLI's clean does, and any write-back's `changed` precedes `done`.

### 8.5 `reset`

`reset { profile?, all?, yes?, plan?, interactive, command }` — `lw reset
[<profile> | --all] [-y]` (spec §16.30: the profile's build directories, or
with `all` every build directory the workspace knows, orphaned ones
included, removed from disk and their units returned to `unconfigured`; the
profile is kept) — has the outcomes of `build`, plus `confirm`. The server
plans the reset (spec §16.30: the directories to lock, the directories on
disk to remove, whether cached state is cleared without a directory), after
resolution and before any lock or side effect, and then answers:

- with nothing to reset: `refused`, with the `nothing to reset for <scope> —
  no build directories to remove.` line, exit code 0 and `stream = "out"`;
- without `yes`: `confirm` (`lines`, `plan`, `profile_key` — absent for
  `all`; the client names the scope from it in its question and refusals) —
  no lock taken, nothing changed. `lines` are the listing (`Will remove N
  build directories and reset <scope> to unconfigured:` and one line per
  directory, or the line for cached state without a directory); `plan` is an
  opaque token of the planned scope, lock set and removal set. The client
  shows the lines and asks the user; a confirmed one sends `reset` again
  with `yes` and that `plan`;
- with `yes` and a `plan`: the server plans again; a plan whose token
  differs is `refused` (`the build directories to reset changed since they
  were listed — run lw reset again`, exit 1) before any side effect —
  compared before the nothing-to-reset check, so a listed plan whose
  directories vanished is refused as changed — so a reset never removes a
  directory the user was not shown. An equal plan is `accepted`, and its
  task prints no listing (the client showed it);
- with `yes` and no `plan` (`-y` on the command line): `accepted`; the task
  prints the listing first, as the CLI's reset does before its deletion.

Its task's `meta.kind` is `reset`; `meta.profile` is the profile's key, or
absent with `meta.scope = "all"` for `all`; `meta.units` are the planned
units (for `all` every configuration unit with a build directory; an
orphaned directory has no unit and is not listed). An accepted reset does,
and prints, what the CLI's reset does: the workspace operation lock (spec
§16.30) taken first, then the build-directory locks of spec §16.6 for every
directory of the lock set, **exclusive**, in canonical order (a dead
holder's lock reclaimed and its state recovered as for a build; a held one
ends the task with the refusal naming the holder, nothing removed). With every lock held
and before anything is removed, the reset plans again and compares the token
with the plan it listed: a directory that appeared or vanished in between
ends the task with the same `the build directories to reset changed since
they were listed — run lw reset again`, exit 1, the locks released and
nothing removed. The removal is the build-directory deletion of spec §4.6
and §4.7: each path validated first; units sharing a directory are one
deletion batch; the cache says `unknown` on disk before a tree is removed
and the units are reset only after its removal succeeded; a directory still
used by a configuration outside the reset is kept, its state cleared for the
reset units only; `all` then removes the orphaned directories the same way.
The reset then checks that every removed directory is gone from disk,
waiting out a delete-pending directory for the CLI's bound: a directory
still present ends the task with the `reset failed — N build directories
could not be removed:` lines, a deletion that does not complete with `reset
timed out — …`, both exit 1; success prints `RESET OK: <scope>`. Cancelling
during the removal stops it between entries (`reset stopped: <reason>`);
what was removed stays removed and the cache stays `unknown` (never reset
after a partial removal, spec §4.7); the locks are held until the removal
has stopped and are then released, the operation lock last. The reset writes
the cache exactly when the CLI's reset does, and its write-back's `changed`
precedes `done`.

### 8.6 Confirmation

A server never prompts. An operation whose CLI form asks the user before
acting (a confirmation, a picker) either is `declined` for that form
(profile onboarding, §8.1) or is asked by the client before it sends the
request, the request then carrying the answer (`force`, §8.2, §9). `reset`,
`Maintenance/1.execute_deletion` and `nuke` (§22) and
`Workspace/1.trust_accept` and `delete_user_prefs` (§6) ask one: the server
returns what the question shows (`confirm`) and the answer travels with a
token of what was shown, so the server acts only on the plan the user
confirmed. A token is opaque, valid only for the request it answers, and
compared again before any side effect.

## 9. `loomworks.Launch/1`

On `/launch`: a launch is split — the server **prepares** it, the client
**executes** it. The program is the user's own — interactive, possibly
long-running, attached to a terminal — so it never runs in the server.

### 9.1 `prepare_run`

`prepare_run { profile?, target?, project?, kind?, cwd?, extra?, no_build?,
quiet?, prefix?, force?, build_scope?, verbose?, interactive, command }` carries the
parsed command line of `lw run` (spec §16.17): `profile` and `target` (the
operands; no `target` for the default target), `project` (`--project`),
`kind` (`--target` / `--launch`), `cwd` (`--cwd`, sent as given: the launch
resolves it — variables expanded, relative to the workspace root), `extra`
(the arguments after `--`), `no_build` (`--no-build`, also set by
`--dry-run`), `quiet` (`--print` / `--dry-run`), `prefix` (true when
`--prefix` is given) and `verbose` (`-v`), as for `Build/1.build`, for the
preparation's dependency build and deploy steps (`    copy …` /
`    up to date …`). The wrapper itself and the report format stay with the
client and do not change what is prepared; `prefix` only lets the server
refuse a device target, after the validity gate and before deploy, with the
`--prefix cannot wrap a device target …` line. Likewise a `cwd` for a device
target (a module-declared one, spec §11.4) is refused there with the
`--cwd does not apply to a device run …` line and exit code 2. The outcomes
are those of `Build/1.build`; it is also `declined` for a profile with a
foreign kit (spec §18.1). An accepted request runs as a task
(`meta.kind = run`) that does, and prints, what the CLI's run does before its
`running …` line, in the same order:

1. unless `no_build`, the profile's build: the build-directory locks taken as
   for a build, the build steps of §8.2 (every gate and line), then the locks
   **released** — they are held for the build only;
2. the launch target resolved against the built tree (spec §16.17, "Launch
   target selection": the named target, else the default target, else the
   sole launchable one; the same messages for none, ambiguous and unset) and
   its validity gate;
3. unless `no_build`, the deploy steps (spec §8), after the locks were
   released;
4. the launch spec resolved — variables and `${VAR}` expanded in the
   client's environment (§5).

`done` then carries `exit_code` 0 and `launch` (§4.4) — or a nonzero exit
code and the failure line (a failed build, no such target, a failed deploy,
`cannot resolve launch: …`). A target found foreign only by probing its
built artifact (spec §18.1, no kit platform) is known only after the server
built it: the task ends with `exit_code` 0, no `launch`, and `device =
true`, before any deploy (of the `target` build scope: before its
post-build deploy, §9.3); the client then continues the run itself from the
deploy. The task, and every lock, ends before the program starts; the server
keeps nothing of the run.

### 9.2 `prepare_debug`

A debug launch takes the same split: the server prepares it, the client
hands the result to its debugger, which starts the program — the program is
never the server's. `prepare_debug` takes the arguments of `prepare_run`
except `quiet` and `prefix` (no report, no wrapper), has the outcomes of
`Build/1.build`, and runs as a task (`meta.kind = debug`) doing steps 1–4 of
§9.1 in the same order, with the same gates and lines. `done` then carries
`exit_code` 0 and `debug` (§4.4).

Whether an adapter is installed in the client's debugger, its install hint,
and the adapter-specific request shape (spec §8.9.6, spec/integrations/debug/)
stay with the client, which checks the first before it sends the call.
There is no device debug (spec §18; spec §11): a device target, or a target
found foreign by its kit or by probing its artifact (spec §18.1, §18.11),
ends the task nonzero — before the build when the kit tells, otherwise once
the build probed it — with the refusal of debugging a foreign target
(spec §18.11) as its failure line (a device target, which has no artifact to
name: `'<target>' is a device target; this host cannot debug it. …`);
`prepare_debug` is never `declined` for it. The kit-token check precedes
everything (build and deploy alike). The artifact probe precedes every
deploy of the profile scope; of the `target` scope (§9.3) it follows the
launch target's own unit and precedes the post-build deploy — the pre-build
deploy steps necessarily run before it, since the artifact they precede does
not exist yet.

### 9.3 Build scope of a launch

`prepare_run` and `prepare_debug` take an optional `build_scope`: `profile`
(the default: steps 1 and 3 of §9.1, as `lw run` builds) or `target` — in
place of steps 1 and 3, the launch flow of spec §8.8.4 steps 3–6: the
launch's dependencies (explicit `depends_on` and deploy-source projects, a
deploy source in the configuration it names), the pre-build deploy steps,
the launch target's own unit, the post-build deploy steps. Each build in it
takes the build-directory locks of the units it builds, for that build only,
and resolves against the requested profile (its environment, variables and
build gate), whether or not it is the active one; a single-target build
builds the unit's own build directory, the one it locked. Once the launch
target's own unit built, the artifact is probed before the post-build
deploy steps: a foreign one ends a debug as refused (§9.2) and a run with
`device = true` (§9.1), the post-build deploy left to the client. A failing
step ends the task with its failure line, the later steps not run. Its
deploy steps run asynchronously, a cancel stopping between two copies, and
its steps are reported as §4.3 describes; `force` is the answer to the
artifact-conflict question (spec §5.9), which the client asks before the
call as before a build. With `no_build` neither scope builds or deploys.

### 9.4 `build`

`build { profile?, project?, target?, kind?, force?, interactive, command }`
(addressed as `prepare_run` is, plus `force`) builds a launch target as the
launch flow of spec §8.8.4 steps 3–5 does, as one task (`meta.kind = build`)
with the outcomes of `Build/1.build`: the launch target is resolved as
`prepare_run` resolves it; a resolution or validity refusal (including the
abstract-configuration gate), or an error while planning the steps, ends the
task nonzero with no steps, before any build (there is no `refused` reply);
then the launch's dependencies (explicit `depends_on` and deploy-source
projects, a deploy source in the configuration it names), the pre-build
deploy steps, and the launch target's own unit (its one target where the
module builds single targets) run in that order — the phases of the `target`
build scope (§9.3) up to and including the target's own unit (without its
artifact probe, post-build deploy steps or launch resolution), and for a
device target (spec §11) then its post-build deploy steps. Each build
takes the build-directory lock of the unit it builds, for that build only;
the deploy steps run without locks and record their freshness in the
workspace cache. `force` is the answer to the artifact-conflict question
(spec §5.9), asked by the client before the call. The first failing step
ends the task with its failure line, the later steps not run; when every
step succeeded the task closes with the plain build's line `BUILD OK:
<target>` (the launch target's display name) and `done` carries `exit_code`
0. A cancel (`Tasks/1.cancel`) kills a running build step and stops a deploy
between two copies; the steps not reached are not run. *(Step 5n, part
B2.)* A device target is built like any other, its post-build deploy steps
included, and its install and launch are left to `Devices/1` (§15).

### 9.5 `device_log`

*(Step 5n, part B3; the editor's use, part C3.)* `device_log { task }` — a
task (`meta.kind = device_log`) that streams the device log of the program
a finished `Devices/1.launch` task of the caller launched (`task` its id,
§15), from what that launch recorded: its target, device, process id and
bundle, nothing resolved again. It is addressed and refused as `stop` is:
another client's launch is `forbidden`; a launch that is unknown, still
running, failed or already stopped, one whose process id was not found, or
a module with no log command is the `refused` result.

The task runs in the client's environment (§5). First the module's
log-clear command, when it has one, runs under the device lock (spec §18.7,
waited for as `install` waits; a failed clear is a `note` line, never a
failure); then the module's log command, which takes no lock, with the
process id passed to it when the module asks for strict-pid filtering. Each
line of its output is parsed as the in-process device-log view parses it,
and kept only when it matches both the launch's process id and its bundle,
or whichever of them the launch recorded (a line that does not parse is
always kept); the level filter stays the client's. The task's `start` meta
carries `level`, the module's default log level, when it has one; a client
starts its level filter there. A kept line becomes a record of spec
§19.18: `ts` (the line's time as printed), `level` (`verbose`, `debug`,
`info`, `warn`, `error` or `fatal`; a client shows an unknown level as
`info`), `tag`, `pid`, `message`, and `fields` with `tid`, `domain` and
`proc`; a line that does not parse is a record with only `message` (the
line without its escape sequences) and `level` `info`.

The records travel as this interface's signal `log { task, records,
dropped? }`, not as task frames, to the subscriptions of `/launch` that
name this task or none (`subscribe_args { task? }`, as `Tasks/1.step`), in
order and batched. The server keeps them in a bounded queue, sent at a short
interval and held back while the owner's connection is behind
([PROTOCOL.md](PROTOCOL.md) §14.4); when the queue is full the oldest
records are dropped, and their number is `dropped` on the next `log`, which a
client shows as a gap. Until a subscription names the task, its records stay in the queue (bounded as above; overflow counts toward `dropped`) and the first `log` signal to a subscription naming it carries them. The task ends on a cancel or its owner's disconnect
(nonzero); when the log command exits (its exit code, the queue sent
first); or when the program has exited: its process id is probed every 3 s,
as in-process, and two misses in a row end the task with exit 0 and the
line `the program exited — log stream closed`. A reload of the workspace
does not end it.

## 10. `loomworks.Tests/1`

On `/tests`: the batch test run of `lw test`, and test discovery, runs of
selected tests and debug preparations. These execute in
the server, like its builds; only a test debug session's program is the
client's (§9.2). All methods carry the caller's environment (`needs_env`).

### 10.1 `run`

`run { profile?, junit?, extra?, no_build?, verbose?, interactive, command }`
— the plan form of `lw test` (spec §16.16: each unit's native runner, then its
saved test targets) — has the outcomes of `Build/1.build`; `junit` is the
`--junit` path, made absolute by the client against its working directory,
`extra` the arguments after `--`, for the plan's steps, `no_build`
`--no-build`, and `verbose`, as for `Build/1.build`: the task streams the
command lines of spec §16.4 *Verbose*. The plan's pre-build checks are made before acceptance: their
notes travel with the reply (§4.1, role `plain`), and a refusal is `refused` with the CLI's
message and exit code (a foreign kit's registered tests with no saved test
target, spec §18.6, pointing at `lw test --target` and `lw test-target add`;
arguments after `--` for a plan of both kinds, exit 2). A plan with saved
test targets on a unit a foreign kit builds runs them on a device, which
stays with the client: `declined` (`profile '<p>' builds for <platform>;
device test runs stay in this process`). Its task's `meta.kind` is `test`.

An accepted run is the test plan of spec §16.16: the build-directory locks
taken as for a build and held across the build AND the test steps (a native
runner may rebuild), unless `no_build` the build steps of §8.2 in their
for-test form (a unit whose runner rebuilds itself is not built separately
unless it has saved test targets; no steps → no `building profile:` line),
the units' targets parsed, every saved entry resolved before the first step
(a missing one fails the test run with the CLI's message; under `no_build`
also the spec §16.16 "Skipping the build" checks — an unconfigured unit, an
unbuilt executable, a self-rebuilding runner that cannot skip its rebuild —
with the CLI's lines and exit 1, the locks held across those checks and the
steps, and its stale-build notes), then each step with its `==> [test] …`
line — a native runner (`<project>: <runner>`), or a saved test target (its
launch's deploy unless `no_build`, its working directory, `${target_dir}`,
the gtest results option, its one-line outcome) — every step run even after
one failed, its JUnit file at the requested path (one per step when several;
a warning line when none was written) with its `JUnit: <path>` line, and
finally either `no tests to run for profile '<p>'`, or the per-step summary
and `TESTS OK: <profile> (<n> step[s])`, or the failure `<k> of <n> test
step[s] failed` with exit 1. Each program is spawned as a build step is
(streamed, cancellable). A build step that fails ends the test run as it
ends a build. A saved target whose artifact is found foreign only once built
(no kit platform) is not run on a device by the server: its step fails with
a line saying so.

`run` has native runners with an authoritative exit status, no per-case
results and no `results` signal; it marks `view.Tests/1` `stale` like any
build.

### 10.2 Discovery, runs and results

The methods below act on the **active profile** and its `view.Tests/1`
(§14.3), and name nodes by their view ids (`{ id }`, a `TestNodeRef`); an id
that no longer names a node of the view (a re-discovery dropped it, the
active profile changed, an earlier session's id) is refused as a stale
reference (§1.2), with the message `no such test`, before acceptance.

- **`discover { force? }`** — task-streamed (`meta.kind = discover`), the
  outcomes of `Build/1.build`. In the caller's environment, for each unit of
  the profile in project-key order, the discovery of spec §8.9.3
  (every TestUnit's entries merged, the saved test targets
  included, the configured-here and foreign-kit rules applied — such units
  get their view state, not a tree). A unit whose tree is current
  (discovered since its last configure or build ended and its saved list
  last changed) is not probed again unless `force`. Probing a unit runs its
  test programs from its build directory, so it takes that build directory's
  lock (spec §16.6; within the server it waits behind a running build or
  test run of that directory; a holder in another process fails fast, and
  the unit's state is `error` with the busy line) for the probe only. Each
  probed unit's line is `==> [discover] <project>/<configuration>` followed
  by its outcome (`<n> tests`, the failure). A unit's failure does not end
  the task: it is that unit's `error` state, and the task ends 0 with
  `DISCOVER OK: <profile> (<n> tests, <k> failed)`. A cancel stops between
  units and at a probe's program (killed as a build step is): the units
  already probed keep their new trees, the others their earlier ones, and
  the view stays `stale`. The view's `update` is sent before `done`.
  `done.result` is `{ exit_code, error?, tests, failed }`: the number of
  tests of the profile's units after discovery (their discovered entries no
  other entry is the parent of: the cases, and the targets without cases)
  and of units whose discovery failed.
- **`run_cases { select?, no_build?, extra? }`** — task-streamed
  (`meta.kind = test`, `meta.units` the units of the selection), the
  outcomes of `Build/1.build`. `select` is a non-empty array of
  `TestNodeRef`, runnable nodes: a `target` node runs its executable whole,
  a `suite` or `test` node with a filter; absent, every runnable top-level
  node of every unit of the profile, each its own step. `no_build` skips the
  build; `extra` are arguments appended to every test step's program. The
  selection's nodes are resolved first (a stale or non-runnable one refuses
  the call before acceptance). The units a run **covers** are its selected
  nodes' units, or for run-all (no `select`) every unit of the profile with
  tests to discover (not `not_configured`, `foreign` or `no_tests`). Then, as
  the plan of `lw test` (§10.1): the build-directory locks of every covered
  unit taken up front in canonical order and held across the build and the
  test steps — within the server waiting (FIFO) behind another task of the
  same directory, so a second client's run waits for the first; a holder in
  another process fails fast. Before its build, a run first **discovers**
  each covered unit whose tree is not current (not discovered yet in this
  session, or a configure, build, clean or reset of it ended since — its
  tree is then stale), as `discover` probes it (its `==> [discover]` line
  and outcome, its record and the view's `update`), so an undiscovered unit
  is never silently skipped and a stale tree's nodes run as the unit now has
  them: a selected node the re-discovery no longer has ends the task with the
  stale-reference message, and a unit whose discovery fails runs nothing
  (its failure line; the task then ends 1). A selected node that has no
  test command, or that the re-discovery made non-runnable, ends the task
  with its message (the refusal before acceptance covers only the stale or
  `runnable = false` nodes known at acceptance). Then, unless `no_build`,
  the build of the selection's targets (each selected node's executable
  target of its unit, as `{ project, target }` targets of `Build/1.build`; a
  unit whose node has no single target, or run-all, builds the unit) with
  the build-step sequence and its failure lines, then the test steps.
  Run-all runs **per top-level node**: one structured run of each runnable
  top-level node of every covered unit (the node's `test_command`, as a
  selected `target` node runs), never a TestUnit's `test_command_all`. A test
  step runs one TestUnit's structured harness (spec §8.9.2 `test_command`
  through the owning TestUnit, spec §8.9.4), selected nodes of one
  executable combined into one invocation where the TestUnit can filter
  them so, each step announced `==> [test] <project>: <name>` and spawned as
  a build step is (streamed, cancellable). Each step writes its results file
  to its **own** path (spec §16.40, removed once parsed; never a fixed path
  in the build directory), so
  concurrent runs never share one. The server reads the harness's per-case
  progress from the step's output and sends it as `results` (batched, at
  most about 4 per second); on the step's end the results file is
  authoritative and its cases are sent once more as `results`. The summary
  is `TESTS OK: <scope> (<n> passed)` or `<k> of <n> tests failed` with exit
  1; every step runs even after one failed. A cancel kills the running step;
  its cases still `queued` or `running` become unknown (their status
  removed, the earlier last result not restored). `done.result` is
  `{ exit_code, error?, cases, counts }`: `cases` an array of
  `TestCaseResult` (every case the run reported, in report order), `counts`
  `{ passed, failed, skipped, errored }`; it carries `discovery_error` when a
  covered unit's discovery failed.
- **`prepare_debug { select, no_build? }`** — task-streamed
  (`meta.kind = debug`), the outcomes of `Build/1.build`. `select` is a
  single `TestNodeRef` object (one runnable node; not an array, unlike
  `run_cases`). The locks and build of a `run_cases` of that node (the locks
  released when the task ends), then `done` carries the `debug` spec (§4.4)
  of the test step `run_cases` would have run — program, arguments with the
  filter and the results option (its own results file as above), working
  directory and environment as that step's — with the language and adapters
  resolved as for a launch (§4.4: a saved `launch` entry's `debug`
  languages, otherwise the primary language of the unit's module), and a
  `prepared` token: `done.result` is `{ exit_code, error?, debug?,
  prepared? }`. The client runs the program under its debugger; a foreign
  kit or device target is refused as in §9.2.
- **`collect { prepared }`** → `{ cases }` (an array of `TestCaseResult`,
  empty when the program wrote no results) — a call, not a task, and
  mutating: it parses the prepared step's results file, records its cases as
  the nodes' last results, removes the file, sends `results` and the view's
  `update`, and returns the cases; a file that is missing (the session ended
  before the program wrote it) records nothing for them. A `prepared` token
  is the calling connection's: it is dropped, with its results file, by its
  `collect`, by the connection's close, and when the server stops. A token
  this connection does not hold (already collected, or of a closed
  connection) is `refused`.
- **`result { id }`** → `{ id, status?, duration?, message?, output?,
  truncated?, errors }` — the node's last result: `output` its captured
  output (at most its last 256 KiB, `truncated` then true; from the results
  file's per-case output, else the step's lines between the case's start and
  end), `errors` an array of `{ message, file?, line? }` (absolute,
  `/`-separated paths) as the TestUnit's parser gives them. A node with no
  last result answers only `id` and an empty `errors`; a stale id is
  `refused`.
- **Signal `results { seq, task_id?, cases }`** — the per-case progress of a
  running `run_cases` (any client's) and the cases a `collect` recorded
  (`task_id` then absent): `cases` an array of `TestCaseResult`, each with
  its current `status`. Sent to every subscriber of `/tests`, batched (at
  most about 4 per second per run), never `initial`. It is a delta on top of
  `view.Tests/1`: a client applies it to its copy of the view, and on a
  `seq` gap or a new session generation it calls `view.Tests/1.get`, whose
  state already includes every change `results` carried. A run's last
  `results` precedes the view `update` that ends it.

**Last results** are kept in the server's memory per node for the session.
A re-discovery keeps the last result of a node whose `id` survives.

## 11. `loomworks.Toolchains/1` and `loomworks.Profiles/1`

`Toolchains/1.list`, `Profiles/1.compiler_cache` and `tool_choices` are
queries: read-only, they change neither the model nor any file, and run in
the client's environment against the model as it is (loading it when none
is loaded, never unloading it for another environment). A failed query, or a
workspace the server cannot load, is `refused` (`message`); a request the
server does not carry is `declined` (`reason`). The other methods below are
commands (§6).

- **`Toolchains/1.list {}`** (on `/toolchains`) → `{ outcome = "ok", tools }`
  — the toolchains each module type detects in the client's environment,
  detected once per call: module type → list of `{ key, label, tool_data }`,
  `key` absent for a module whose single toolchain has none.
- **`Toolchains/1.rescan {}`** *(step 5o)* — detects the toolchains again in
  the client's environment and takes them into the model, as the status
  page's `L` does in-process; a command (§6), with a `changed` when the
  model's toolchains changed. It replies only once detection settled or 45 s
  (the daemon's load wait) passed, and other model requests queue behind it
  meanwhile: a client calls it with a timeout of at least 45 s (the client's
  default of 5 s is too short). A detection that outruns the wait does not
  refuse it (the model may already have changed, §6): the reply is `ok` with
  the warn note `toolchain detection did not finish in time; it goes on in the
  background`, and the daemon signals `changed` when that detection finishes,
  if the toolchains changed. The late detection's result is taken in outside
  the requester's environment scope, as a load's background detection is.
- **`Profiles/1.compiler_cache { profile, project }`** (on `/profiles`) →
  `{ outcome = "ok", cache? }` — `cache` the
  compiler cache that profile resolves for that project, as fields `{ policy,
  tool?, path?, present, stale, msvc_auto_off, applicable,
  not_applied_reason?, not_applied_hint? }` that a client formats as `lw
  profile query … cache` prints it (spec §16); `cache` is absent when that
  project's module does not cache C/C++. It probes the client's `PATH`. An
  unknown profile, a project the profile does not map, or a stale id is
  `refused`.

*(Step 5n, part B2.)* A profile's device is chosen with two writes, not
queries, each in a model segment of the client's environment:

- **`Profiles/1.set_device { profile, device }`** — sets the profile's
  device to one of `Devices/1.list`'s devices (§15), `device` a reference
  (§1.2) to it: its `id`, or its `key` (the serial). The device's serial is
  persisted as the profile's `device` in the working copy;
- **`Profiles/1.clear_device { profile }`** — removes it.

An unknown profile or device, or a stale id, is `refused`.

Each reaches subscribers as `Workspace/1` `changed` and in
`view.Workspace/1` (§14.4); a write that is refused or fails changes neither
`user.json` nor the model and is the `refused` result with its message.

*(Step 5o.)* The other profile commands (§6):

- **`Profiles/1.set_active { profile }`** — makes it the active profile
  (spec §4.2), with `header_changed`;
- **`Profiles/1.create { config_set, tool?, activate? }`** → `ok` with
  `profile { id, key }` (and `config_set { id, key }` when a `{ candidate }`
  set was added — also when the profile could not be saved, the `warn`
  result without `profile`) — materializes a profile of the set (spec §4.1):
  `config_set` a reference, or `{ candidate }`, a token
  `ConfigSets/1.candidates` (§20) gave for an automatic set, which is added
  first; `tool` one of `tool_choices`' toolchains, absent
  for a profile without one (shown incomplete, never a guessed default); an
  existing profile of that set and toolchain is returned, not duplicated. A
  new profile's intent is `local`. With `activate` it is also made active.
  While a toolchain detection is running it is `refused` at once with
  `toolchains are still being detected` (exit code 1, a state refusal the
  client may retry), never waiting for the detection;
- **`Profiles/1.tool_choices { config_set }`** → `{ outcome = "ok", tools:
  [{ module, key?, label } | { sdk = true, key, label }] }` — the toolchains
  a profile of that set can use, detected in the client's environment: the
  keyed toolchains of its projects' module types, then the resolved SDKs
  relevant to them; `config_set` as for `create`,
  and refused as `create` is while a toolchain detection is running;
- **`Profiles/1.add_tool { profile, tool }`** / **`remove_tool { profile,
  tool }`** — adds or removes a toolchain, `tool` its key (§1.2). The
  profile's key is derived again (spec §1.6); its id is kept, and the new
  key propagates as a profile rename does, under the workspace operation
  lock (spec §19.3). `add_tool` of a toolchain the model does not know is
  `refused` with `no toolchain '<key>'`; `remove_tool` of a toolchain the
  profile does not have, with `no toolchain '<key>' on profile '<key>'`.

An SDK's entry in `tool_choices` is `{ sdk = true, key, label }`;
`create`'s `tool` may be `{ sdk = <key> }`. A module's toolchain is
`{ module, key? }`. A `tool` not among `tool_choices`' is `refused` with
`no <module> toolchain '<key>' for this configuration set (see
Profiles/1.tool_choices)`, an SDK's with `no SDK toolchain '<key>' for this
configuration set (see Profiles/1.tool_choices)`.

A profile is deleted with `Maintenance/1.execute_deletion` (§22).

## 12. `loomworks.DebugConfig/1`

The workspace's debug-adapter mapping (spec §8.9.6 "Adapter configuration"),
on `/debug`:

- `adapters {}` → `{ languages: [{ language, adapter, default, known,
  overridden }] }` — one record per known language (`known_languages`): the
  adapter in effect, the integration's default, the adapters known for the
  language (`known`, from the integrations' declarations, never from the
  client's debugger), and whether the working copy overrides the default;
- `set_adapter { language, adapter? }` — sets the language's adapter in the
  working copy (`user.json` `debug.adapters`, never `loomworks.json`), or,
  with no `adapter`, removes the override so the default applies, with a
  `Workspace/1` `changed`. The adapter name is stored as given (a client
  offers `known`). A write that is refused (a stale working copy, spec §2.7,
  or one that is not trusted) or fails changes neither `user.json` nor the
  model, and is the `refused` result with its message;
- `known_languages {}` → `{ languages: [..] }` — every language a module or
  integration declares (spec §8.9.6 "Language-based adapter resolution").

It has no signal of its own: a change reaches subscribers as `Workspace/1`
`changed`, on which a client reads `adapters` again. Whether an adapter is
installed is the client's question (its debugger's adapter table, the
install hint), never the server's.

## 13. `loomworks.LspConfig/1`

What the workspace's language servers are configured with (spec §9), on
`/lsp`:

- `get {}` → `{ state, ready, projects: [{ project, id?, path, entries }],
  options }`, computed with the caller's environment (§5). `state` is the
  workspace's, as in `view.Header/1` (`loaded`, `unloaded`, `error`,
  `refused`); `ready` is whether the active profile's owned databases have
  settled (spec §9.7; also true when there is no active profile or nothing to
  generate). `projects` are in ascending key order (the workspace-entry rule
  of spec §9.8 depends on it), each with its key, its opaque `id` (§1.1), its
  path relative to the root and the entries its module's `lsp_configs` gives
  (spec §8.4). `options` are the working copy's per-server options (spec §2,
  `user.json` `lsp`) as `{ [server]: { [key]: value } }`. `get` never loads
  the workspace: in any state but `loaded` it answers with that `state`,
  `ready = false`, no projects and no options.
- An **entry** carries the core fields `server`, `root_dir`, `db_state`
  (`ready` or `unconfigured`, spec §9.1), `db_dir` and `db_rev`, and passes
  every other field of the module's entry through unread (a module's own
  `build_dir` among them): the schema requires the core fields and allows
  any others, which core never types. `db_dir` is the directory whose owned
  database the entry reads: the module's when it sets one (a redirect to
  another unit's database, spec §8.4), else the project's active build
  directory; absent when there is neither. `db_rev` is an integer, kept per
  `db_dir`, raised each time the server (re)writes that directory's owned
  database (spec §8.4 `refresh_lsp_database`'s `done(true)`), so a database
  that went from absent to present shows although no other field changed.
  Withhold reasons (spec §9.8) are not in the state: deciding them from
  `db_state` and the entry is the client's integrations' job.
- `set_option { server, key, value? }` → `{}` — sets the server's option in
  the working copy (`user.json` `lsp`, never `loomworks.json`), or, with no
  `value`, removes it, with a `Workspace/1` `changed`. A write that is
  refused (a stale working copy, spec §2.7, or one that is not trusted) or
  fails changes neither `user.json` nor the model, and is the `refused`
  result with its message. An unknown server or key, or a value whose type
  (or enum value, or list element type) the server's option schema does not
  accept, is `invalid_args`, before anything is loaded or written. (Unlike
  `DebugConfig/1.set_adapter`, whose adapter name is stored as given: an
  option's schema is core's, so a client cannot know better.)
- Signal `changed { seq }` — carries no state. It is sent when the state the
  server computes with its own environment differs from the one at its last
  `changed` (checked where the views' `update` is, §14: after each model
  segment and committed write), and when an owned database is written (a
  raised `db_rev`). It has no `initial`: a client reads `get` after
  subscribing, and again, with its own environment, on each `changed` and on
  `Workspace/1` `changed` (a difference visible only under the client's
  environment is not signalled). The state is whole, so a missed `changed`
  is recovered by the next read.

## 14. Views

Each view is an interface of its own (`loomworks.view.<Name>`), versioned on
its own, served by the `/views` object. Each has one method, `get` (no
arguments; returns the view's full state), and one signal, `update`,
declared `initial`, whose payload is the same full state: never a delta. A
client replaces its table on every `update`, and after a `seq` gap or a new
session generation it calls `get` again; subscribing after a reconnect
re-hydrates the client with no further protocol. The server sends `update`
at the point where it checks `Workspace/1.header_changed`: after every model
segment and every committed write, before the acknowledgement of the call
that caused the change, and only when the view's state differs from the one
last sent on that subscription. Unless a field says otherwise it is
required; an optional field is absent (never `null`) when it does not apply,
and a client shows an unknown enum value as neutral.

### 14.1 `loomworks.view.Header/1`

The always-warm header. Its state is `Workspace/1.header`'s fields with the
same meaning (`root` string, `state` one of `loaded` / `unloaded` / `error`
/ `refused`; optional `name` string, `active_profile` string (the active
profile's key), `error` string, §2; and `pid` integer, `lw_version` string,
`session_generation` integer, required in `Workspace/1.header` but optional
here), plus:

- `active_profile_id` (string, optional) — the active profile's opaque id;
  present exactly when `active_profile` is. It is what a client puts in an
  `{ id }` reference (§1.2).
- `config_set` (string, optional) — the name of the active profile's
  configuration set; present when `state` is `loaded` and a profile is
  active.
- `config_set_id` (string, optional) — that configuration set's opaque id;
  present exactly when `config_set` is.
- `diagnostics` (`"error"` or `"warn"`, optional) — the highest severity
  among the workspace's structural diagnostics (spec/ui.md §1); absent when
  there are none or the workspace is not loaded.
- `trust` (`"user"` or `"cache"`, optional) — present only when `state` is
  `refused` by a trust refusal (spec §17.4): the refused file, the working
  copy (`user`) or the cache (`cache`). Absent for a newer-schema or journal
  refusal.
- `version` (string, optional) — the running loomworks version of the `lw`
  that built the view, resolved like `_meta.written_by` (spec §2); absent
  when unknown.

`Workspace/1.header` is unchanged: `view.Header/1` is a separate interface
and adds its fields only to itself.

### 14.2 `loomworks.view.ProjectsIndex/1`

What a client needs to show each project's state under the active profile
and to map a file to its project. Its state
is `{ projects }`: `projects` (array, required) holds one record per project
of the workspace, ordered by key; it is empty when the workspace is not
loaded. A record:

- `id` (string, optional) — the project's opaque id.
- `key` (string) — the project's key.
- `label` (string) — the project's display text (§1.1). A project has no
  display name of its own (spec §1.2), so its `label` is its key; a client
  shows `label`, never derives it.
- `type` (string) — the project's module type (`cmake`, `meson`, …); a
  project of an unknown or rejected type (spec §8.0) is listed with its
  declared type and without `active`.
- `path` (string) — the project's directory relative to the workspace root,
  `/`-separated: its declared `path`, or its key when it declares none.
- `abs_path` (string) — the workspace root joined with `path`, absolute and
  `/`-separated, as the server resolves it (not case-folded; a client
  compares it with its own path normalization, spec §2.3 —
  case-insensitive on Windows).
- `active` (object, optional) — present when the active profile maps the
  project; absent with no active profile:
  - `configuration` (string) — the name of the project's configuration in
    the active profile.
  - `unit_id` (string, optional) — the opaque id of the configuration unit
    for the project's configuration and tool; absent when the profile has no
    unit for the project yet.
  - `tool_key` (string, optional) — the key of that configuration's tool;
    absent for a module whose single toolchain has none.
  - `state` (string) — the configuration unit's state as the right column of
    spec §3.4 names it (`unconfigured`, `configured`, `built`,
    `configure_failed`, `build_failed`, `unknown`, `configuring`,
    `building`, `deleting`); `unconfigured` when the profile has no unit for
    the project yet. It includes a task any client runs in the server. Only
    state changes send `update`; a build's progress never does. The
    profile's overall state is computed by the client from these states.

### 14.3 `loomworks.view.Tests/1`

The test tree of the active profile. It differs from the views above in one
point: the per-case progress of a running test is **not** sent as `update`
but as the thin `Tests/1` `results` signal (§10.2), so a run of thousands of
cases does not resend the tree several times a second. `update` is sent,
under the rule above, when discovery changed the tree, when `stale` or
`discovering` changes, when a run starts (its selected nodes become
`queued`) and when it ends (their results are the last results); `get`
always answers the **current** state, a running run's per-case statuses
included, so a client that saw a `seq` gap in either `update` or `results`
recovers with one `get`. The server sends a run's last `results` before the
`update` that ends it. Its state is `{ state, profile?, profile_id?, stale,
discovering?, units }`:

- `state` — the workspace's, as in `view.Header/1`; `units` is empty unless
  `loaded`.
- `profile` (string, optional) — the active profile's key; the view covers
  the active profile only, and is empty (`units` = `[]`) with none.
  `profile_id` (optional) — its opaque id.
- `stale` (boolean) — the tree may no longer match the build: no discovery
  has run for the active profile in this session yet, or since then a
  configure, build, clean or reset of one of its units ended (by any client),
  its saved test target list changed (spec §1.3.4), or the active profile
  changed. Only `Tests/1.discover` clears it. The server never discovers by
  itself: discovery runs test programs and needs the client's environment.
- `discovering` (TaskId, optional) — the task of a `Tests/1.discover` that is
  running for this profile, of whichever client.
- `units` (array) — one record per configuration unit of the active profile,
  in project-key order:
  - `id` (string, optional) — the configuration unit's opaque id.
  - `project` (string), `configuration` (string) — the keys, as in
    `meta.units`.
  - `state` — `ok` (discovered; `nodes` holds its tree), `pending` (not
    discovered yet in this session), `not_configured` (not configured on
    this machine, spec §17.8: discovery runs programs from the build
    directory), `foreign` (its kit builds for another platform, spec §18.1),
    `no_tests` (its module has no TestUnit and it has no saved test targets),
    `error` (discovery failed).
  - `message` (string, optional) — why, for `error`, `not_configured` and
    `foreign`.
  - `nodes` (array) — the unit's test tree in discovery order, parents before
    their children; empty unless `state` is `ok`. A node:
    - `id` (string) — the node's id: an opaque id issued by the server,
      **scoped to its unit**, so the same `Suite.Case` in two projects is two
      nodes. It is stable while the node's unit, TestUnit and name are,
      across re-discoveries in one session; a client never parses it.
    - `kind` — `target` (a test executable, a native runner's registered
      test, or a saved test target), `suite` (an explicit node: a client
      never infers suites from case names) or `test`; a client shows an
      unknown kind as a plain node.
    - `parent` (string, optional) — the parent node's `id`; absent for a
      top-level node.
    - `name` (string) — the display text (the saved-entry name with its `#2`
      suffix, spec §8.9.2; the case name without its suite).
    - `file` (string, optional), `line` (integer, optional) — the source
      location, absolute and `/`-separated, as discovery maps it.
    - `runnable` (boolean) — whether `run_cases` and `prepare_debug` accept
      it; a missing saved entry is a non-runnable node with `status`
      `errored` and its `message`.
    - `source` (string, optional) — where discovery found it: `ctest`,
      `meson`, `gtest` (probed cases), `saved` (a saved test target,
      spec §1.3.4), or a module's own runner name; open-ended (a string, not
      an enum) — a client shows an unknown source as neutral.
    - `status` (optional) — `queued` or `running` while a run that selected
      it is in progress, else its last result in this server session
      (`passed`, `failed`, `skipped`, `errored`); absent when it has none.
      Last results live in the server's memory: they survive a client's
      reconnects, not a server restart.
    - `duration` (integer, optional, milliseconds), `message` (string,
      optional, the first failure line) — of the last result.

Output and error locations are not in the view: a client reads them with
`Tests/1.result { id }` (§10.2) when it shows them.

### 14.4 `loomworks.view.Workspace/1`

*(Step 5n.)* What the status page's body shows (spec/ui.md §1.1):
Diagnostics, Suggestions, Profiles, Orphaned Build Dirs, Configuration
Sets, Projects and SDKs. The header, LSP, Debug Adapters and Tasks sections
have their own sources. The view is the body's whole contract: every field
the status page reads to render these sections is listed here, and the page
reads nothing else from the model. Its state is `{ published, modified,
diagnostics, suggestions, profiles, orphaned, config_sets, projects, sdks,
sdk_providers }`; its arrays are empty when the workspace is not loaded.
Each `id` is an opaque id a client puts in an `{ id }` reference (§1.2),
optional because the in-process builder leaves it out:

- `published` (boolean) — whether the workspace has a published
  `loomworks.json` (spec §2.4).
- `modified` (boolean) — whether the working copy differs from the published
  baseline anywhere (spec §2.4).
- `diagnostics` (array) — the workspace's structural diagnostics, each
  `{ severity, message, source?, target_fold_key? }`: `severity` `error` or
  `warn`; `source` (string) what raised it; `target_fold_key` (string) the
  status page's fold key of the item it is about (the page opens that fold),
  absent for an informational diagnostic. A client never parses
  `target_fold_key`.
- `suggestions` (integer) — the number of actionable suggestions (spec/ui.md
  §1.1); the suggestions themselves are `lw health`'s.
- `profiles` (array) — one record per profile, ordered by key:
  - `id` (string, optional), `key` (string), `label` (string, §1.1),
    `description` (string, optional), `config_set` (string, optional; the
    configuration set's name, the missing set's name when `orphaned_set`);
  - `active` (boolean), `modified` (boolean), `orphaned_set` (boolean; its
    configuration set no longer exists);
  - `intent` (string, optional) and `removed_upstream` (boolean, optional)
    — its publish state (below);
  - `status` (string) — the profile's overall state as display text,
    summarised from its units' states (`built`, `configured`,
    `unconfigured`, `2 building, 1 failed`, `1/3 cleaning`, …; `empty` when
    it maps no project). A client shows it as it is, never parses it;
  - `incomplete` (boolean) — a module of the profile has no resolved tool
    for a language its configurations need (spec/ui.md §1.5);
  - `busy` (boolean) — an operation runs on the profile: one the server
    runs for any client, or a task observed in the server (spec/ui.md
    §1.5);
  - `running` (boolean) — a unit of the profile has a configure or build of
    the server's own running;
  - `origin` (string, optional) — the origin label of the task that keeps
    the profile busy when it is only a task another client started
    (spec/core/daemon.md §19.15 `meta.origin`);
  - `tools` (array) — `{ module, key?, label }`, one per module type of its
    projects, ordered by module type;
  - `toolchain` (array, optional) — the Toolchain row (spec/ui.md §1.5): one
    `{ key, label, resolved, languages }` per tool key the profile selects,
    `resolved` false for a key no module's registry knows, `languages` the
    languages the tool provides; present when a module of the profile needs
    a tool or the profile selects any, so an empty array is `(none —
    incomplete)`;
  - `compiler_cache` (object, optional) — the Compiler cache row (spec/ui.md
    §1.5): `{ text, stale }`, `text` the row's text, `stale` whether a
    configured unit was configured with another launcher than the one now
    resolved (it needs a reconfigure); absent when no
    project of the profile caches C/C++;
  - `compat_error` (string, optional) — why a tool cannot build a project
    of the profile;
  - `artifact_conflict` (boolean) — a unit's output artifact is claimed by
    another profile's (spec §5.9);
  - `last_result` (object, optional) — the outcome of the last operation
    that finished on the profile: `{ status, message? }`, `status` the
    task's final status as in `Tasks/1` (§7), `message` its end message. It
    changes only when an operation ends (its change sends `update`), is
    kept while the next operation runs, and survives a reconnect; absent
    before the first operation ends;
  - `device_capable` (boolean, optional) — `true` when a module of the
    profile has devices (spec §11): the page shows the device row, `none
    selected` without `device`; absent otherwise;
  - `device` (object, optional) — the profile's device, only with
    `device_capable`: `{ id?, key, label, state, provider? }`, `key` its
    serial, `label` its name (the serial when it has none), `state` and
    `provider` as in `Devices/1.list` (§15). A chosen device the registry
    does not have online is `{ key, label, state: "offline" }`, `label` its
    serial;
  - `default_target` (string, optional) — the display name of the profile's
    default launch target; with it `default_target_valid` (boolean) whether
    it still resolves, and `default_target_description` (string, optional)
    its launch configuration's description;
  - `units` (array) — one per project the profile maps, in the profile's
    order:
    - `project` (string), `type` (string, the project's module type),
      `configuration` (string), `unit_id` (string, optional);
    - `state` as in §14.2, and `deleting_reason` (string, optional) —
      present when `state` is `deleting`: `cleaning` for a clean, `deleting`
      for a deletion or reset;
    - `missing` (boolean) — the configuration has no source;
    - `compat_error` (string, optional) — why the profile's tool cannot
      build this project;
    - `overwritten` (boolean) — another unit has since overwritten its
      output artifact (spec §5.9);
    - `launcher_changed` (boolean) — its compiler launcher changed since it
      was configured;
    - `artifact_block` (object, optional) — `{ profile, path? }`: a build of
      the unit now would overwrite the output artifact of the built unit of
      that profile (spec §5.9 gate, without `force`); the client asks before
      a build and sends its Yes as `force` (§8.6);
    - `tools` (array of strings, optional) — the labels of the tools that
      build the configuration under the profile;
    - `build_dir` (string, optional) — the unit's build directory as cached;
    - `targets` (object, optional) — its parsed build targets, by name, each
      `{ type, artifact?, dependencies? }`; absent before its first
      configure on this machine.
- `orphaned` (object) — `{ configurations, stray_dirs }` (spec/ui.md §1.6):
  `configurations` one `{ id?, key, build_dir? }` per orphaned cached
  configuration, `id` its build directory's (what
  `Maintenance/1.execute_deletion` takes, §22), `key` its cache key,
  `build_dir` its cached build directory; `stray_dirs` the stray build
  directories, as strings (a stray directory is no entity; §22 names it by
  this string).
- `config_sets` (array) — one record per configuration set, ordered by
  name: `{ id?, name, description?, active, modified, intent?,
  removed_upstream?, mappings, missing }`; `active` whether it is the active
  profile's set; `mappings` an object, project key → configuration name;
  `missing` an object, project key → `true`, for each mapped configuration
  that was removed or has no source.
- `projects` (array) — the project's declaration as the status page shows
  it (spec/ui.md §1.8), ordered by key with orphaned projects last:
  - `id` (string, optional), `key` (string), `type` (string), `path`
    (string, as in §14.2), `description` (string, optional) and
    `description_from_module` (boolean, optional; `true` when the module
    supplied the description, spec/ui.md §1.16);
  - `modified` (boolean), `intent` (string, optional), `removed_upstream`
    (boolean, optional) — its publish state (below);
  - `orphaned` (boolean) — its module type is unknown or rejected (spec
    §8.0);
  - `running` (boolean) — a unit of the project is shown configuring or
    building;
  - `needs_refresh` (boolean) and `refresh_reasons` (array of strings,
    optional) — the module reports that the project's declaration is out of
    date with its sources, and why;
  - `tests` (object, optional) — the project-wide saved test targets line
    (spec/ui.md "Saved test targets line", spec §1.3.4): `{ source?,
    invalid?, entries }`, `source` where an inherited list comes from (absent
    for the item's own), `invalid` when the declared list is malformed (then
    `entries` is empty), `entries` one `{ label, missing }` per entry;
    present only for a module that parses targets and when a list applies;
  - `configurations` (array, optional; absent when the project declares
    none) — ordered by name (below);
  - `presets` (array, optional) — the module's preset configurations
    (`CMakePresets.json`), ordered by name, each `{ name, generator?,
    toolchain_locked? }`;
  - `launches` (array) — the launch configurations, ordered by name: `{ id?,
    key, label, description?, target?, command?, args? }`, `id` the launch
    configuration's (§1.1), `key` and `label` the launch's name, `target` /
    `command` / `args` as declared. A launch carries **no publish state** of
    its own (below);
  - `deploy` (array) — the deploy declarations, ordered by destination, each
    `{ destination, sources }`, `sources` the normalized source descriptors;
  - `variables` (object) — variable name → `{ type, default? }`, the
    project's declarations;
  - `type_config` (object) — `{ fields }`: the module's editable
    `type_config` fields **in the module's order**, each `{ name, label?,
    kind?, placeholder?, value? }`, `value` the project's current value.
- A configuration (`projects[].configurations[]`):
  - `id` (string, optional), `key` and `label` (strings, its name);
  - `modified`, `intent?`, `removed_upstream?` — its publish state (below);
  - declared fields, as the files and the module give them: `abstract`
    (boolean; it has no variant, so it is only inherited), `inherits`
    (string or array of strings), `toolchain_locked` (boolean, optional; its
    toolchain is fixed by a toolchain file), `role` (string, optional),
    `toolchain` (string, optional; the toolchain file), `generator`
    (string, optional);
  - `description` (string, optional), `description_from_module` (boolean,
    optional);
  - `user` (boolean) — declared by the user, not emitted by the module;
    `auto_gen` (boolean) — emitted by the module;
  - `source_missing` (boolean) — it exists only in the cache, its source is
    gone;
  - `unresolved_inherits` (array of strings) — the names in `inherits` that
    resolve to no configuration;
  - `dependents` (array of strings) — the configurations that inherit it;
  - `compiler_overrides` (array of strings) — the reserved compiler option
    keys it sets, which are ignored (a non-blocking warning);
  - `running` (boolean) — a unit of it is shown configuring or building;
    `overwritten` (boolean) — a unit of it was overwritten (spec §5.9);
    `tools_configured` (integer) — how many of its units are configured
    with a tool;
  - `tests` (object, optional) — its saved test targets line, shaped as the
    project's; an entry is `missing` only when a unit of the configuration
    was configured on this machine;
  - `options` (array) — its resolved options, ordered by key, each `{ key,
    value, source? }`, `source` the configuration it inherits the option from
    (absent for its own);
  - `variables` (array, optional) — the project's variables resolved for it
    (spec §1.3.1) under the active profile and its compiler family (as
    `Projects/1.declaration`'s `compiler_family`), ordered by name, each `{ name, value?, source,
    own }`: `source` `profile`, `project` or the name of the configuration
    that sets it, `own` whether the configuration sets it itself, `value`
    absent for an unfilled blank; present when the project declares
    variables.
- `sdks` (array) — `{ id?, key, label, path?, resolved, kits }`: `id` the
  SDK's (what `Sdks/1.remove` takes, §21), `path` the SDK's
  path, `resolved` whether the SDK resolves on this machine, `kits` the
  display labels of its kits (empty unless `resolved`).
- `sdk_providers` (integer) — how many SDK providers are installed; the SDKs
  section offers adding an SDK only when there is one.

The publish state of a profile, configuration set, project or configuration
(spec §2.4): `modified` whether it differs from the published baseline;
`intent` where it is published — `local` (`user.json` only), `shared`
(`loomworks.json` only) or `local+shared` (both); `removed_upstream` whether
it has effective intent `local+shared` and was removed from the published
file since the baseline (absent means false). A client shows an unknown
`intent` as neutral. A launch configuration or a variable declaration has
no publish state in the model (spec §2.4 "Per-item granularity"): a change
to it shows as its project's `modified` (spec §2.4 "Modified indicator"),
and it is published with its project.

**Progress is not in the view.** The view carries no build progress — no
percent, elapsed time or progress message, for a profile or a unit. A
client takes them from `Tasks/1` (§7): the task's `start` meta names the
profile and units it runs on, its `progress` frames (PROTOCOL.md §14.2)
give the percent, its `start` and `done` the elapsed time; `Tasks/1.list` gives a late joiner each running
task's start time and last percent. The status page overlays these on the
view's rows as the editor's remote and editor-owned tasks
(spec/core/daemon.md §19.16 "Tasks in the task runner", "Running state",
"UI"), so a profile row shows the same progress whichever client started
the task. The outcome of the last finished operation is not progress but
state: it is the profile's `last_result`, in the view.

`update` is sent under the rule above; a unit's state change or a profile's
`last_result` change sends it, a build's progress never does.

## 15. `loomworks.Devices/1`

*(Step 5n, part B2.)* The workspace's devices (spec §11), on `/devices`. The server keeps a registry of the
devices its modules found; a client never lists or probes devices itself.

A device target is reached only as its profile's default target (`target`
omitted): a name never selects one, since `prepare_run`'s named targets are
build targets and launch configurations (spec §16.17).

- `list {}` → `{ devices: [{ id, key, label, state, provider, profiles? }] }`
  — the registry as it is; it never probes a device. Each device is an
  entity record (§1.1): `key` its serial, `label` its name (the serial when
  it has none). `state` is `online` or
  `offline` (a client shows an unknown state as neutral), `provider` the
  module that found it, `profiles` the keys of the profiles that chose it.
- `scan {}` — a task that asks each module that has devices to list them,
  in the client's environment (§5), and updates the registry (a device a
  module no longer lists stays, `offline`); a cancel ends it at once,
  nothing merged.
- `install { profile?, project?, target?, kind? }` — a task that installs a
  built device target, addressed as `prepare_run` addresses it (§9.1), on its
  profile's device: the profile is resolved before the task is accepted (a
  refusal is `refused`); a target that does not resolve or is not a device
  target, a profile with no device, or a module that cannot install it ends
  the task nonzero before anything runs. The module's command runs in the
  client's environment, its output on the task, under the target's
  build-directory lock (fail-fast) and then the device lock (spec §18.7:
  waiting for a live holder, announced once on the task) — the order of spec
  §19.3.
- `launch { profile?, project?, target?, kind? }` — a task that launches
  that target there, addressed and refused likewise, under the device lock
  only; its `done` carries `{ pid?, bundle? }` (the program's process id,
  probed when the module names its bundle).
- `stop { task }` — stops the program a finished `launch` task of the caller
  launched (`task` its id), with the module's stop command under the device
  lock: `ok` (also when the module has none), else `refused` (no such
  launch, a launch still running, a failed stop); another client's launch is
  `forbidden`. A launch is stopped once, and forgotten when its owner
  disconnects.
- `changed` (signal) — the registry changed (a scan, a device appearing or
  going away, a profile choosing a device); a client reads `list` again.

A profile's device is chosen with `Profiles/1.set_device` and
`clear_device` (§11).

## 16. `lw.internal.Snapshot/1`

On `/internal`, flagged `same_build` (PROTOCOL.md §9.4): `get { scope }`
returns the workspace's file-shaped state for a client of the same build. It
is a same-build facility, never a stable contract, and not specified here.

## 17. Module interfaces

A module provides an interface only for a feature core has no abstraction
for (signing setup); a feature core abstracts (devices,
toolchains, build steps) reaches clients through the core interface, which
the module feeds through the module interface of spec §8. A module's
interfaces live in its own namespace (its module id, PROTOCOL.md §9.1) on
`/modules/<id>`, and their schemas ship with the module. Each declared
interface version is mounted only if every method in its schema has a
handler and every handler a method in its schema; a mismatch rejects that
interface version, not the module. The wire version of a module interface is
independent of the in-process module API version (spec §8.0).

## 18. Conformance fixtures

The fixtures a transcript names (PROTOCOL.md §18, `fixture`) are `empty`,
the default; `shell`, a shell project `app` with configuration `Debug`, the
configuration set and trusted profile `dev` and a launch configuration
`hello`, also a project `lib` outside the set and a launch configuration
`staged` depending on it; and `tests`, that project as one of the
harness-only test module `teststub` with two test targets and `dev` active;
and `devices`, that project as one of the harness-only device module
`devstub` (devices `SER1`, online, and `SER2`, offline), `dev` active with
its device target `app` as the default target and no device chosen.
The runner binds `lw_version`, `env` and `root` before the handshake.

## 19. `loomworks.Projects/1`

*(Step 5o.)* A workspace's projects and what they declare, on `/projects`.
`candidates`, `declaration`, `expand_preview` and `unit_options` are
queries (as §11's); the others are commands (§6). A configuration is named
by a reference (its id, or its key with the project); a launch
configuration as §1.2 says; a variable, deploy destination or
`type_config` field by its project and its name.

- `candidates { path, type? }` → `{ outcome = "ok", key, path, types,
  mappings, configurations, tools?, upgrade_preview? }` — what adding that
  directory as a project would declare, detected in the client's
  environment: the derived key and relative path, the module types that
  detect it, the configurations the module offers, a proposed mapping into
  each configuration set (set name → configuration name), the toolchains it
  can use (`tools[] { key, label, inherited? }`: only the one the profiles
  already use, `inherited`, when there is one), and the profiles a toolchain
  choice would upgrade (`upgrade_preview[] { tool, from, to }`, profile keys).
  A path outside the root (exit 2) or an unknown `type` (exit 2) is refused,
  as is a missing directory;
- `add { key, type, path?, mappings?, tool? }` → `ok` with `project { id,
  key }` — declares the project, maps it into each configuration set by
  `mappings` and, with `tool` (`{ key }`), upgrades the affected profiles to
  that toolchain; an upgrade that fails after the project was added is a
  `warn` note (§4.1). `path` (else the directory named by `key`) is checked
  as `candidates` checks it — outside the root is refused with exit 2, a
  missing directory refused — and stored relative to the root. A keyed
  module's project without `tool` is added unmapped, with a `warn` note
  naming the mappings not made; a mapping into a configuration set that does
  not exist is a `warn` note naming it. An unknown `type` is refused (exit 2);
- `declaration { project }` → `{ outcome = "ok", configurations, launches,
  deploy, variables, options, type_config, module, compiler_family? }` — the
  project's declaration as the working copy holds it (merged as spec §2.4
  merges it), for a client's editors: each configuration's and launch
  configuration's declared fields with its `id` (`configurations[] { id,
  key, user?, fields, ... }`, `user` for a user configuration; `launches[]
  { id, key, fields }`, or `invalid` instead of `fields` when the
  declaration is not a table). Beside what is declared, what the
  configuration editor shows of it, derived and read-only, under the active
  profile: the module's default `languages` and whether it `has_options`
  (`module`); the `compiler_family` of the active profile's tool for the
  project (spec §1.3.1), absent without one; and per configuration
  `default` (generated by the module, its name fixed), `source_missing`
  (cache only, spec §4.5: not offered as a base), its resolved `variant`
  and the base that supplies it (`variant_from { id, key }`; absent when
  it declares its variant itself), the options
  it has from the project or a base and does not declare
  (`inherited_options[] { key, value, from, configuration? }`, `value`
  untyped as the module's options are, `from`
  `project` or `configuration`), each project variable's value for it
  (`resolved_variables[] { name, value?, from, configuration? }`, `from`
  `project`, `configuration` or `profile`; no `value` while blank), and
  the build directories of its units (`build_dirs[]`, as cached);
- `configuration_save { project, configuration?, name, fields }` → `ok`
  with `configuration { id, key }` — creates a user configuration (no
  `configuration`), or updates one; a `name` other than its key renames it,
  propagated to configuration sets, profiles and the cache (spec §4.8) under
  the workspace operation lock;
- `configuration_remove { project, configuration }` — removes the
  declaration; its build state stays, as an orphaned configuration (spec
  §4.5);
- `options_save { project, options }` — the project's options;
- `launch_save { project, launch?, name, data }` → `ok` with `launch { id,
  key }` — creates a launch configuration (no `launch`) or replaces one's
  declared fields; a `name` other than its key renames it as spec §8.7
  does (profiles' default targets, units' target entries and saved test
  entries follow), its id kept. The rename writes only the working copy
  (the units' target entries are not cached), so it takes no workspace
  operation lock; `launch_remove { project, launch }`;
- `deploy_save { project, deploy? }` — the project's whole deploy
  declaration; no `deploy` removes it;
- `variable_save { project, variable?, name, data }` — declares a variable
  (no `variable`) or replaces one, `variable` its current name (a rename
  when `name` differs); `variable_remove { project, variable }`. A
  `variable` the project does not declare is refused, `no variable '<name>'
  in project '<key>'`;
- `type_config_set { project, field, value? }` — one of the module's
  editable `type_config` fields (§14.4); no `value` clears it; any other
  field is refused (exit 2);
- `expand_preview { project, profile?, templates }` → `{ outcome = "ok",
  values }` — each template expanded as a launch of that project would
  expand it (spec §1.3.1, §8.7), under `profile` or the active profile, in
  the client's environment; an unresolved reference stays as written. No
  `profile` and no active profile is refused;
- `unit_options { unit }` → `ok` with `options` — the build options of a
  configured configuration unit (`unit` `{ id }`, its id from a view), as the
  module's `get_options` reads them from its build directory (spec §8):
  an array of `OptionGroup` / `Option` nodes (`{ label, children }` /
  `{ key, value, value_type?, choices?, helpstring? }`). Read-only, no lock;
  `refused` when the unit is not configured, is being deleted or cleaned
  (its build directory may be mid-removal) or its module has no options.
  The read runs off the model queue: the unit is checked and its build
  directory taken in a model segment, then the module's async read runs and
  the reply follows. A unit deleted or cleaned meanwhile can make the read
  fail (`refused`, no build options).

A project is removed with `Maintenance/1.execute_deletion` (§22).

## 20. `loomworks.ConfigSets/1`

*(Step 5o.)* The configuration sets (spec §1.4), on `/projects`.
`candidates` is a query; the others are commands (§6).

- `candidates {}` → `{ outcome = "ok", sets: [{ config_set?, name, auto,
  description?, candidate? }] }` — the declared sets (`config_set` their id)
  and the automatic ones the projects allow (`auto`), each automatic one
  with `candidate`, an opaque token `Profiles/1.create` and `tool_choices`
  accept in place of a reference;
- `add { name, mappings }` → `ok` with `config_set { id, key }`;
  `mappings` project key → configuration name;
- `update { config_set, name?, mappings }` — replaces the mappings; a
  `name` other than its key renames it, propagated to profiles and the
  cache (spec §4.10) under the workspace operation lock;
- `remove { config_set }` — removes the declaration; its profiles stay,
  shown with a missing set (spec §4.4);
- `generate_defaults {}` — adds the sets the projects' configurations
  suggest (one per common configuration name) that do not exist yet; the
  `notes` name the sets added.

## 21. `loomworks.Sdks/1`

*(Step 5o.)* The workspace's SDKs (spec §10), on `/toolchains`. `detect` is
a query; the others are commands (§6).

- `detect { provider? }` → `{ outcome = "ok", providers: [{ id, label,
  path_prompt?, found: [{ path, version? }] }] }` — the installed SDK
  providers (or the one named) and the installations each finds (path, and
  version when known), in the client's environment; `path_prompt` is what
  the provider calls a typed path;
- `add { provider, path }` → `ok` with `sdk { id, key }` — declares the SDK
  and detects the toolchains again (as `Toolchains/1.rescan`, §11), so its
  kits are offered; `path` must be absolute (the daemon's working directory
  is not the client's): with a known provider a relative one is `refused`
  (`SDK path '<path>' is not absolute`), nothing declared;
- `remove { sdk }` — removes its declaration and detects the toolchains
  again, so its kits leave the toolchains and no profile resolves against
  the removed SDK.

`add` and `remove` wait for that detection as `rescan` does (§11): they
answer only after it settled or 45 s passed, other model requests queue
behind them, and a client calls them with a timeout of at least 45 s. A
detection that outruns the wait leaves the reply `ok`, with a warn note
(`add`: `SDK '<key>' added; toolchain detection did not finish in time; it
goes on in the background`; `remove`: `SDK '<key>' removed; toolchain
detection did not finish in time; it goes on in the background`), and `changed` follows when it
finishes. The in-process editor's add and remove start the same detection
without waiting for it.

## 22. `loomworks.Maintenance/1`

*(Step 5o.)* On `/maintenance`.

`execute_deletion { target, plan?, yes? }` — task-streamed, `meta.kind =
"delete"` — removes build state and what it belongs to, with the outcomes
of `reset` (§8.5) and its confirmation (§8.6). `target` is exactly one of:

- `{ profile }` — the profile and the build directories only it uses; the
  profile is deactivated first when active;
- `{ unit }` — a configuration unit's build directory and cached state:
  a unit by its id from `view.Workspace/1`, or `{ project, configuration }`
  (the `snapshot.index` `config_units` shape);
- `{ build_dir }` — an orphaned build directory: a build directory by its
  id (in `view.Workspace/1` `orphaned.configurations`), or `{ key }` (the
  orphan row's key);
- `{ stray_dir }` — a stray build directory, the path as
  `view.Workspace/1` lists it;
- `{ orphans = true }` — every orphaned and stray build directory;
- `{ project }` — the project's build state, then its declaration, then
  its profiles' toolchain downgrade, in that order in the one task.

The server plans the deletion after resolution and before any lock (what
it would remove and which build directories it must lock), then answers:
with a `plan` the new plan differs from `refused` (`the build directories
to delete changed since they were listed`, exit 1), considered before the
empty check, so a listed plan whose directories vanished is never
`nothing to delete`; with nothing to delete `refused` (`nothing to delete`, exit 0, `stream =
"out"`); without `yes` `confirm` (`lines` the listing a client shows,
`plan` a token of the planned removal and lock set) with nothing locked or
changed; with `yes` and an unchanged `plan` it is `accepted`; with `yes` and no `plan` it is
`accepted` and the task prints the listing first. An accepted deletion
takes the workspace operation lock, then the build-directory lock of every
directory of the plan (exclusive, canonical order; a held one ends the task
with the refusal naming the holder, nothing removed), plans again under
the locks and ends with the same changed-plan refusal on a difference, and
then removes as spec §4.6–§4.7 specify: each path validated against the
workspace root, the cache `unknown` on disk before a tree is removed, the
units reset only after its removal succeeded, a directory still used
outside the target kept. A `{ project }` whose build directories are not
all removed is kept (declaration, profiles and its cache entries
`unknown`), and the task ends `refused`. A `stray_dir` not under the
workspace root is `refused` (`path outside workspace: <path>`), one not in
the server's current set of stray directories `refused` (`not a stray
build directory: <path>`), and one that holds a live build directory
`refused` (`directory holds a live build dir: <path>`); it is locked like
any other directory, so one a running configure owns is refused. Cancelling stops between directories (`delete stopped: <reason>`);
what was removed stays removed and its cache entry `unknown`. A key form
naming nothing is `refused` (`no configuration unit '<project>/<configuration>'`,
`no build directory '<key>'`), as an unknown profile or project key is. A
successful deletion's task prints `DELETE OK: <label>` last. The task's
writes' `changed` precede `done`.

*(Optional, part B6.)* `nuke { plan?, yes? }` — task-streamed, `meta.kind =
"nuke"` — the editor's nuke and `lw nuke`: the workspace's build state
(`.nvim/build/`, the build and health caches, the owned language-server
database areas, spec §4.6). As spec §19.3 requires of a nuke, its locks are
checked before it lists, also without `yes`: a held workspace operation
lock or build-directory lock is `refused` naming the holder. The server's
own running tasks are neither passed over nor stopped: while any runs, the
nuke is `refused`, the refusal listing those tasks. Otherwise it confirms
as `execute_deletion` does; an accepted nuke checks the locks again, takes
the workspace operation lock and every build-directory lock, unloads the
model, removes, and loads the workspace again (`header_changed`; every id
issued before is stale). A failed area check aborts it before anything is
removed.
Like trust_accept, nuke is served while the workspace load is refused.
