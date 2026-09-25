> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 16. Headless / Standalone Execution

The system runs in two execution environments: the **interactive editor
host** and a **non-interactive (headless) host**. All contracts in §1–§15
hold in both, except those explicitly scoped to the editor — UI (§6),
Neovim commands (§14), LSP integration (§9), auto-load (§13), and live
file-tracking reconciliation (§2.5). A headless host performs a bounded
subset of behavior: resolve a profile and run its build / clean / test
tasks to completion, reporting a process exit status.

### 16.1 Runtime-host neutrality

The behavioral contract is independent of the host that provides the Lua
and asynchronous runtime. Any host supplying the required primitives — a
structured filesystem, process spawning, an asynchronous I/O event loop,
and JSON encoding/decoding that distinguishes object, array, and null
(including the empty-object vs empty-array distinction, §1.9) — MUST
produce identical results. State serialized by one host MUST be readable,
with identical meaning, by any other host.

### 16.2 Source of truth without the working copy

A headless invocation MUST be able to resolve any **published** profile to
its build commands from the published snapshot (§2.1) plus the cache (§2.3)
alone, with no working copy (§2.2) present. Publishing (§2.4) therefore
MUST emit a snapshot self-sufficient for this resolution. When a working
copy is present it MAY be read as input. A **build** (§16.4) MUST NOT create
or modify it — build invocations are non-mutating so CI runs stay
reproducible; an explicit **management** operation MAY write it (§16.9).

### 16.3 Explicit profile selection

The active profile is working-copy state (§4.2) and is not assumed in a
headless invocation. The profile to operate on MUST be selected explicitly
by the caller. Absent an explicit selection, a non-interactive build-shaped
invocation (build, clean, test, run, reset, …) is **always** an error — even when
the workspace has exactly one profile, and regardless of the working copy's
active profile: it never uses the active profile and never infers one. The
error lists the available profiles and points at the invoked verb's named form
(e.g. `lw test <profile>`; a unique substring is accepted, below) and at read-only introspection (§16.18) for
deterministic selection in scripts. An interactive invocation MAY fall back to
the active profile, then to the sole profile; the read-only listing / show
verbs and the profile fill-value management verbs keep their own no-argument
defaults (below, §16.9, §16.18).

A profile MAY be named by a **truncated tool selector** — a prefix of a tool
key that omits trailing detail, such as a compiler family plus major version
(`ninja-clang-18`) or a toolchain family plus major version without its
edition (`msvc-17`). A CI matrix can therefore name a toolchain without
pinning either the exact patch version or the specific edition installed on a
given runner image.

Matching is **anchored at segment boundaries**: the selector must be followed
in the candidate key by a version separator or a segment separator, so a
truncated selector never resolves a different segment (a `…-1` selector
matches neither `…-18` nor `msvc-17`). It is a prefix, not a substring —
`msvc-17` does not match `ninja-msvc-17-…`. Among candidates the highest
matching version wins; when candidates carry no distinguishing version (two
editions of the same toolchain) the choice MUST still be deterministic and
independent of enumeration order. When a selector matches more than one
**profile** the invocation is an ambiguity error, never an arbitrary pick.

A profile MAY also be selected by a **stable positional number**. Every
profile listing assigns each profile a number from a fixed ordering — the
profiles sorted ascending by key, numbered 1..N — so a profile's number is the
same in every listing and does not depend on the active profile or on display
order. Wherever a command takes a profile, a bare integer operand is accepted
in place of the key and resolves to the profile at that position; an
out-of-range number is an error naming the valid range. Profile keys are never
bare integers, so name and number selection never collide. Numbers are an
**interactive convenience only** — the ordering is recomputed each run and a
number may shift when profiles are added or removed. Scripts and CI MUST use
keys, and read-only machine introspection (§16.18) resolves keys exclusively
and never accepts a number.

This named-selection procedure — number, then exact key, then unique
boundary substring, with an ambiguity always an error — applies **uniformly**
to every verb that takes a profile operand (build, clean, test, run, and the
management verbs select / show / remove / target). What differs per verb is
only the **no-argument** fallback (§16.9/§16.18): a build-shaped invocation
refuses without an explicit profile, while read-only listing and show default
to the active profile. As surface conveniences that widen accepted input
without changing behavior, item-creating verbs accept `create` and `add`
interchangeably (and removal accepts `rm`, with `target unset` an alias of
`target clear`); launch management (show / remove / set) accepts the §16.17
target addressing — a single `[<project>:]<name>` operand and/or
`--project` / `--launch` flags — in addition to the two-positional
`<project> <name>` form; and a configuration set may be created with positional
`<project> <config>` pairs as well as `project=config` tokens.

### 16.4 Cache-cold vs cache-warm

Build-unit readiness derives from the cache (§3.1). For a build unit with
no valid cache entry, a headless invocation MUST perform the full readiness
sequence — tool detection (§3.3) then configure (§5.2) — before build. For
a unit with a valid cache entry it MAY build directly. Tool identity
resolves from live detection when available, otherwise from cached tool
data (§1.5, §2.3); resolution MUST succeed from cache alone when detection
has not run.

**Why a configure runs.** Whenever a headless build (re)configures a unit it
reports, on one line before the configure's output, why and how: the build
gate's reason — `first configure`, `previous configure failed`, `forced
(--reconfigure)`, a staleness reason (§5.1: `configure record from an older
lw`, `options changed (<names> added|changed|removed)`, `module configuration
changed`, `configuration environment changed`, `compiler launcher changed`),
`project files changed`, or `build directory missing` — prefixed with the
module's classification (§8.1 `reconfigure`): `configure: <reason>` for a
first configure (or when the module does not say), `full reconfigure
(<mechanism>): <reason>`, or `reconfigure (in place): <reason>`. For example
`full reconfigure (--fresh): configure record from an older lw`. The editor
logs the same line.

**Forced full reconfigure.** `lw build --reconfigure` configures every unit of
the profile before building, whether or not the gate would, forcing each
module's **full** reconfigure (§5.1 *Forced full reconfigure*) — for a build
tree whose configure state the user no longer trusts. Its reason reads
`forced (--reconfigure)` (`first configure` for a never-configured unit). It
is transient (nothing is recorded that makes a later build reconfigure again).

**Failure after a cache-compatibility finding.** The post-configure scan (§5.1,
§8 `cache_compat_scan`) is advisory and never gates the build. When a build
step then fails for a unit whose recorded scan has an `"error"` finding (the
applied launcher fails those compiles), the runner's closing failure message
gains one line pointing back at it. The recorded scan is the one refreshed after
that build step (§8 `cache_compat_stamp`): when the build tool re-ran the
generator during the step and the compile data changed, the finding is re-scanned
first — reported before the closing line — so a flag the build just introduced is
named and one it just removed is not, e.g. `build failed — 1870 compiles use
/Zi, which sccache will fail (see the scan finding above; lw health; lw help
cache)`.

A build is additionally gated by the output-artifact conflict rule (§16.28):
a unit whose build would overwrite an artifact currently owned by another
built unit is refused unless the caller forces it.

### 16.5 Toolchain provisioning boundary

A headless host detects toolchains present on the system; it does not
install them. Provisioning build tools is outside the system's contract,
except SDK-provided toolchains (§10).

### 16.6 Non-invasiveness

A headless build is read-only toward project sources and toward the working
copy. Only the cache and build directories are written, under the safety
rules of §2.3 and §5.3. This contract does not itself serialize cross-process
concurrent access to a shared build directory; a host MAY add advisory
exclusion. loomworks does: configure/build/clean/reset (§16.30) hold a
**per-build-directory advisory lockfile** — an `O_EXCL` create (atomic across
processes) with an
mtime heartbeat so a crashed holder's lock goes stale and is reclaimed. The
editor and the CLI share this lock, so neither operates on a directory the other
holds — in particular a reset (§16.30) cannot remove a directory the other is
building, and a build cannot enter a directory a reset is removing. Acquisition
is **fail-fast** (the loser reports the holder and declines rather than waiting). A stale lock is reclaimed automatically after
the heartbeat window; `lw unlock` clears one immediately. The CLI also releases
its build locks on interrupt (SIGINT/SIGTERM) as well as on normal exit, so an
interrupted (Ctrl-C'd) build does not leave a lock for the stale-reclaim window.

### 16.7 Reporting

Success or failure is reported via process exit status; task output streams
to standard output and standard error. No editor UI is required or
produced.

Every command documents itself: `lw help <command>` and, equivalently,
`--help` / `-h` anywhere among a command's own arguments (never after the `--`
that hands the rest to a build tool or program) print that command's help and
exit 0 — the flag is never read as an operand such as a profile name. This
holds for the host-level commands too (version reporting, self-update,
installation, pin management): asking for their help never performs them.
A sub-command's help (`lw help <command> <sub-command>`, or `--help` after the
sub-command) prints only that sub-command's part of the command's help, with a
pointer to the whole; a sub-command the help does not document falls back to
the whole command's help. User-facing help is self-contained: it never cites
specification sections.

### 16.8 Host-determined module availability

The set of modules available to a host is determined by that host. A build
unit whose module is unavailable in the current host is reported and
skipped; consistent with §8.0, its declaration is preserved and does not
invalidate the workspace or other units. A management host MAY extend its
available set by acquiring modules (§16.20).

### 16.9 Builds are read-only; management may author

A **build** (§16.4) is read-only toward configuration: it never creates or
modifies projects, configurations, configuration sets, or profiles. This is
what keeps CI runs non-mutating and lets the headless host coexist with the
editor.

An **explicit management** operation MAY author — bootstrap a workspace,
select the active profile, or (where supported) create/edit items — but only
when the caller invokes it directly; it is never part of a build. Management
writes follow the same working-copy model as the editor (§2.4): they land in
the working copy (§2.2), and the published snapshot (§2.1) changes only on an
explicit publish. A read-only / CI invocation runs no management operation.

Selecting the **active profile** (§4.2) is such a management operation, and it
needs no interactive terminal when the profile is named: the name resolves by
the §16.3 named-selection procedure and the selection is written to the working
copy. A companion form **clears** the selection (no active profile). Selecting
the profile that is already active, or clearing when none is active, writes
nothing and says so (`(unchanged)`). Only an *unnamed* selection — an
interactive picker — requires a terminal; non-interactively it is an error that
names the scriptable forms.

Configuration editing addresses a configuration's fields by a **dotted param
grammar** (`get`/`set`/`unset`): a bare field (`inherits`, `languages`, a
module field), a keyed namespace (`options.<KEY>`, `variables.<NAME>`,
`env.<NAME>` for the configuration environment, §1.3.3), and — for a
compiler-family override (§1.3.1) — the three-segment
`overrides.<family>.<name>` for a variable, or the four-segment
`overrides.<family>.env.<NAME>` for an environment variable, where
`family ∈ {clang, gcc, msvc}` (clang-cl counts as clang). A dotted param outside
these namespaces (e.g. `foo.bar`) is **rejected** with an error listing the
valid forms rather than stored as a literal dotted field name; module fields
are bare names. A reserved compiler-driver name in `env.<NAME>` or
`overrides.<family>.env.<NAME>` (invariant 13, matched case-insensitively —
§1.3.3) is **refused** by the same validation the editor applies: `set` exits 1
and writes nothing (the runtime strip-with-warning applies only to a
hand-edited file). Setting `env.PATH` (any case) succeeds but prints a warning
on stderr, naming the full param that was set, that it replaces the tool's
PATH (§1.3.3). An env name that matches an existing entry ignoring case
replaces that entry, keeping the new spelling, and says so (§1.3.3). A `cache`
value (`variables.cache`, `overrides.<family>.cache`, or a profile fill) outside
the valid policies is refused with the valid values listed (§1.3.2). `set` writes the value; an empty value or `unset` clears it,
pruning an emptied family and an emptied override block. A malformed shape
(`overrides` alone, or `overrides.<family>` without a name) and an unknown
family are rejected at parse time; naming a variable not declared in the
project's `variables` is rejected by the same validation the editor applies
(§1.3.1). A `set`/`unset` that changes nothing — `unset` of a param that
is not set, or `set` to the value it already has — writes nothing, says so
(`… is not set` / `(unchanged)`) and exits 0; the same holds for clearing a
profile fill value that is not set, or setting one to the value it already
has. A reminder to publish is printed only after
an edit that **changed** a configuration reaching the published snapshot
(§2.4 effective intent) — and, likewise, after creating a configuration only
when it would reach the published snapshot. `get` returns the resolved string for the full path, or the
sub-dict for `env`, `overrides`, `overrides.<family>` and
`overrides.<family>.env`. `show` lists the configuration's `env` alongside its
`options`.

A management host MAY also **rename** an item in place — a project (by key), a
user configuration (by `(project, configuration)`), or a configuration set (by
name). A rename is atomic and propagates to every item that references the old
name (configuration-set mappings, profile mappings, and derived profile keys),
so the model stays consistent without a rebuild; an invalid or colliding new
name is rejected by the same validation the editor applies. Renaming a
configuration is confined to **user** configurations — a module-generated or
preset variant has no user-owned name to change.

A management host MAY also **declare or remove a project variable** (§1.3.1),
addressed by `(project, variable)`. Declaring accepts a `type` (`string` or
`path`, defaulting to `string`) and an OPTIONAL `default`; when the default is
omitted the variable is declared **blank** — it has a type but no value, the
profile-fill case (below). Declaring is create-or-update (it upserts the
type/default of an existing declaration); an invalid type, or a name that
collides with a built-in (§1.3.1), is rejected by the same validation the
editor applies. Removing drops the declaration together with any configuration
overrides of it. This is the non-interactive path that bootstraps a variable so
the override (`variables.<name>` above) and profile-fill (below) operations —
both of which require the variable to already be declared — become usable.

A management host MAY also **set or clear a profile's fill value** for a blank
project variable (§1.3.1), addressed by `(profile, project, variable)` and
defaulting to the active profile when no profile is named. `set` writes the
value into the working copy (§2.2) under that profile; the mirror operation
clears it. Naming a variable not declared in the project's `variables`, or a
profile that does not exist, is rejected. These fill values are per-machine
working-copy state and are never published (§2.4). Filling a profile's blank
variables this way is the non-interactive path through the build gate (§5):
under `--no-interaction` a build refuses while any blank remains, naming the
variable and profile to fill.

### 16.10 Toolchains outside the search paths

*(Reserved. Section numbers §16.11+ are referenced throughout, so this number
is retained rather than reused.)*

A build machine whose toolchain is not on the host's search paths makes that
installation usable by **declaring it** (§10.1) — the declaration is validated,
identified, and produces a toolchain like any detected one, so the profile pins
it and selection (§16.3) applies unchanged.

A per-invocation override that satisfied a profile's pin from a bare executable
path was considered and **deliberately rejected**: probing an executable yields
its own identity, but not the surrounding facts a module needs to build with it
(a build-system generator, for instance). Reconstructing those would mean either
inferring them from the pinned key — keys are opaque identifiers and are never
parsed (§1.5.2) — or silently assuming a default that is wrong for some
toolchains. Declaration avoids this because the provider *constructs* the
toolchain rather than guessing at it.

### 16.11 Runner distribution and system-Lua resolution

The standalone runner separates a **generic runtime host** (the Lua VM and
asynchronous primitives of §16.1) from the **system Lua** (the behavioral
implementation of §1–§15). The host carries no behavioral logic of its own;
per invocation it resolves system Lua from exactly one source, chosen by
precedence:

1. an explicit caller override naming a directory;
2. a **development source** — a working tree designated in host
   configuration — when the caller opts into it;
3. otherwise the **release source** — a verified release bundle.

Absent (1) and (2), the release source is used. The chosen source is fixed
for the whole invocation. The resolution is a host concern: it does not
affect any §1–§15 contract, and system Lua behaves identically whichever
source supplied it.

### 16.12 Release integrity

A release bundle MUST be cryptographically verified against a trusted public
key carried by the host before any of its Lua executes. Verification covers
a signed manifest that binds the identity and content hash of every bundle
artifact; an artifact whose hash does not match, or a manifest whose
signature does not verify, MUST NOT execute. Verification integrity MUST NOT
depend on transport security: a bundle obtained over an untrusted or
intercepted channel is accepted if and only if its signature verifies. A
development source (§16.11) is exempt from verification — it is local,
explicit, and caller-owned. The component that performs verification is part
of the host, never part of the bundle it verifies.

### 16.13 Acquisition and activation

Acquiring a release bundle — an initial install or an update — MUST verify
it (§16.12) before it becomes active. Activation MUST be atomic and MUST NOT
overwrite the code of a running invocation; a failed or partial acquisition
MUST leave the previously active bundle intact, so a runner is never left
without a working system Lua. Acquisition and activation are management
operations (§16.9): they are never performed as part of a build (§16.4), so
a read-only or CI invocation neither fetches nor mutates the active bundle. An
un-pinned acquisition resolves its target release through the active **update
channel** (§16.29).

### 16.14 Host/bundle compatibility

A release bundle declares the minimum runtime-host capability it requires. A
host that does not meet a bundle's minimum MUST refuse to execute it — rather
than fail unpredictably — and MUST report that a host update is required.
Within its compatible range a single host build executes any bundle, so
behavioral updates ship as bundles without replacing the host. Changes to the
host itself reach an installed host through host self-update (§16.32).

### 16.15 Host acquisition integrity

The host cannot verify itself — the component that checks a signature (§16.12)
is inside the host. A host binary's integrity is therefore established
out-of-band: it is obtained and checked against a hash published through a
trusted channel *before* its first execution, and only a matching binary is
run. Installation is that binary placing itself where it can be invoked; it is
not part of the verified-bundle chain and MUST NOT be assumed to have verified
the running binary. Once trusted this way, the host bootstraps the bundle chain
(§16.12–16.13). A later replacement of an installed host (§16.32) is verified
by the already-trusted running host against the signed hash list below, before
the new binary is ever executed.

The published hash list is itself **signed** with the release key (§16.12), and
the acquisition procedure verifies that signature before trusting any hash in
it. This makes the trust anchor the long-lived public key rather than a
per-release digest, so the documented acquisition commands are stable across
releases — a procedure that must be edited for every release invites being
copied stale, or "repaired" by dropping the check. The verifying public key
MUST therefore reach the user through a channel that is not the release
artifacts themselves (e.g. embedded in the documentation).

This establishes provenance, not omnipotence: where the signing key is held by
the same platform that serves the artifacts, a compromise of that platform
defeats both. An acquisition procedure MAY additionally offer verification
anchored outside the project's own infrastructure (e.g. a public transparency
log), which is the stronger check where available.

### 16.16 Headless test runs

A headless **test** invocation resolves a profile and ensures it is configured
and built (§16.4) — **skipping the build of any unit whose native batch runner
rebuilds its own targets (§8.9.2), since that build would be redundant** — then
runs each buildable unit's tests through the native batch runner
(`run_command_all`, §8.9.2) — not the editor's structured per-test path.
Configuration is still ensured for every unit: a self-rebuilding runner assumes
an already-configured build directory, not an unconfigured one. Each runner's process exit
status is authoritative; the invocation's exit status is success iff the build
succeeded and every runner reported success. A unit whose module exposes no
batch runner contributes no tests; a profile with no test runners at all is
reported as such, not a failure. Like a build (§16.4), a test run is read-only
toward configuration (§16.9).

A headless test invocation MAY forward caller-supplied arguments to the native
batch runner (e.g. a parallelism knob), and MAY request machine-readable
(JUnit XML) results written to a caller-specified location — a single file per
invocation, or one file per unit (a label suffix distinguishing them) when a
profile runs several. The runner maps both to its native mechanism; a runner
that cannot emit JUnit reports that without failing the run.

### 16.17 Headless launch (run)

A headless **run** invocation resolves a profile (§16.3) and a **launch
target**, then runs the editor's launch chain (§8.6, "Build flow"): build the
target and its dependencies (§16.4), execute **deploy** steps (§8), and launch.
The launched process's exit status is the invocation's exit status. It runs
**attached to the invoking terminal** — inherited standard input/output/error,
and (on Windows) not hidden — so its output streams live, it can read input,
and a GUI window appears, exactly like launching the binary directly. The
build, clean, and test steps send their tool output to standard output and
error the same way (§16.7); a host able to attach them to the terminal streams
it live, so progress-aware tools (e.g. ninja) see a real terminal, while a host
that can only capture emits the same output once the step exits. The run
differs in being the user's own program — interactive and (where applicable)
windowed. The run is read-only toward configuration (§16.9) and, like the
editor's non-debug launch, excludes debugger attachment and device targets
(both deferred).

**Launch target selection.** The launch target is one of:

- the profile's **default target** (§8.6) when none is named;
- a **named target** — either a **build target** (its executable artifact,
  resolved via the module) or a **command launch configuration** (§8.7).

A configuration pins exactly one configuration per project, so a target
reference needs no configuration qualifier; it resolves within the profile.
Project qualification (`project:target`) disambiguates a bare name that is
present in more than one project. A bare name matching **both** a build target
and a command launch configuration is an error until qualified. Selection is
explicit throughout: with no named target and no default set, the invocation
errors unless exactly one launchable target is in scope — the system never
guesses.

**Positional grammar.** Before any `--`, a run takes zero, one, or two
positional operands:

- **none** — the resolved profile's default target. The profile is resolved
  per §16.3 (the active profile in an interactive host; otherwise the sole
  profile, or an error).
- **one** `<target>` — the named target on the resolved profile (§16.3). A
  single operand is always a target on the resolved profile, never a profile
  selector; run a different profile's target with the two-operand form, or
  select that profile first (§16.9).
- **two** `<profile> <target>` — the named target on the named profile.

Operand count alone distinguishes the one- and two-operand forms.

**Argument forwarding.** Positional arguments after a `--` separator are
forwarded verbatim to the launched program (a command configuration's own
declared arguments precede them). The separator is required to pass arguments,
so the optional operands are never ambiguous with program arguments.

**Launch prefix.** A run MAY interpose a **prefix command** before the resolved launch command: the launched process becomes `<prefix tokens> <resolved command> <arguments>`, executed in the launch's resolved working directory and environment (§8.6) with the same terminal attachment as an unprefixed run (above). The prefix is a host-level wrapper the system does **not** interpret, so it serves any external launcher — a memory checker, tracer, profiler, timing tool, or an interactive debugger invoked on the program (e.g. `valgrind`, `gdb --args`). It is therefore distinct from debugger *attachment* orchestrated by the system (deferred, above): the system execs the wrapper unaware of its purpose. Running the wrapper **inside** the resolved working directory and environment is the point — a caller cannot reproduce it by wrapping the run invocation itself, which would wrap the resolver, not the program. A prefix is **multiple tokens** (e.g. `valgrind --leak-check=full`); it is supplied as an option, so it consumes neither the positional operands nor the forwarded arguments, and a host defines how the tokens are given (a tokenized string and/or a repeatable option). The launched process's exit status remains the invocation's exit status. A prefix on a **device target** is an error — device launch is deferred, and a local wrapper does not apply to on-device execution.

**Command inspection.** A run MAY resolve the launch **without executing it**, reporting the fully-resolved invocation instead: the command and its arguments (a command configuration's declared arguments and any forwarded arguments included), the working directory, and the environment overrides the launch contributes — not the inherited environment. This is a read-only report (§16.9), for inspection or for a caller that drives execution itself. A build target's command is known only once its artifact is (§16.18); an unresolved artifact is reported as unresolved, never guessed (§16.3). Because the working directory and environment are reported rather than applied, a caller that reconstructs the invocation is responsible for reproducing them — the prefix mechanism (above) is the faithful way to run under a wrapper. Whether the dependency build (§16.4) precedes the report or is skipped is a host option.

**Shared code paths.** Resolution, dependency build, deploy, and the launch
command/spec are the same seams the editor drives; the headless runner differs
only in executing the resolved spec directly rather than through the editor's
task runner (§16.1).

**Setting the default target** is a management operation (§16.9): it selects,
per profile, the default build target and writes it to the working copy
(§8.6, "Default target storage"). No target is ever named "default" — the
default is a property of the profile, not a reserved target name.

### 16.18 Headless introspection

A headless invocation MAY **query** read-only facts about a resolved profile
(§16.3) as deterministic, machine-readable output for scripting — most usefully
a project's **build directory**, so a CI job can locate build artifacts without
reconstructing the layout. A query performs no build and no management writes
(§16.9); the build directory it reports is the same deterministic path a build
would use, known once the profile pins a toolchain, so the query is valid before
any build has run. Introspection is scoped to a `(profile, project)` pair, since
a build directory is a per-project coordinate; the reported facts a caller MAY
request include the build directory, the pinned configuration, the last known
build state, the resolved toolchain, and the **resolved compiler cache** — the
launcher core resolved from the effective `cache` policy (§1.3.2), or that no
cache is in effect. The compiler-cache fact reports the resolved launcher name
and whether it is currently present; it never spawns the cache tool.

Introspection MAY also **list a resolved profile's launchable targets** — the
runnable things a launch (§16.17) can name: each project's **command launch
configurations** (§8.7) and its **build targets** (their executable artifacts).
Listing is read-only and performs no build. A command launch configuration is
always enumerable from configuration, but a build target is known only once its
project is **configured** (its artifacts are read from the build tree), so the
listing is complete only for the profile's configured projects and MAY be empty
or partial otherwise; the operation reports that the list is incomplete — and
which project must be configured to complete it — rather than guessing the
missing targets (§16.3). The listing marks the profile's **default target**
(§16.17) among the results. Because it neither builds nor writes, the listing MAY
resolve the **active profile** as its default even in a non-interactive host,
unlike the operations that build or manage state (§16.3, §16.9).

Introspection MAY also present a **single-profile detailed view** — the human
overview (below) narrowed to one resolved profile and only the items it
references: its **configuration set** and that set's project→configuration
mappings, and for each project the set maps its configuration, resolved
toolchain and last known build state; the profile's **toolchains**; its
**resolved compiler cache** (the launcher in effect, or that caching is off /
unavailable / not enabled automatically for an MSVC-style compiler, §1.3.2 —
the latter pointing at the compiler-cache help topic, §16.31); and its
**launchable targets** with the default marked, incomplete when a project is not
yet configured, exactly as the target listing above. Its **diagnostics** are
scoped to the profile — those concerning the profile itself, its configuration
set, and the configurations and projects that set maps — rather than the whole
workspace's set. A profile that leaves a **blank** declared variable unfilled
(§1.3.1) surfaces here (and in the overview below) as a profile-scoped
build-blocking diagnostic naming the variable, and fails `--check`. The profile defaults to the **active profile** when none is
named, like the operations that resolve a default profile; naming a profile that
does not exist, or omitting one with no active profile, is an error that names
the problem. Being read-only, this view MAY resolve the active profile even in a
non-interactive host (§16.9).

The human status overview is likewise read-only — it runs no build and authors
no project or build-system files (§16.9), though it MAY refresh its own internal
advisory caches under `.nvim/` (the suggestion cache of §16.31, whose passive
tier is computed lazily on first display). When no workspace resolves
here (§1.1) it points the user at how to start one, with each suggested command
on its own line. When a workspace does resolve, the overview MAY present the
active profile's launchable targets, marking its default target and — when the
list is incomplete because a project is not yet configured — pointing the user
at how to configure it. When the invocation sits in a linked git worktree whose main
checkout holds a workspace, the hint offers to **pull** that config into the
current worktree (§16.25) as well as to initialise a fresh workspace here; when
the main checkout has no workspace — or the invocation is not in a linked
worktree — it offers only to initialise one. Detecting the parent worktree is a
best-effort, time-bounded hint: it never fails the report, and a slow or absent
git only adds a small bounded delay.

The overview MAY also surface the workspace's **diagnostics** — the same set
the interactive host presents — as a top section shown only when non-empty,
with each per-item warning or error also shown inline under the profile,
configuration set, or project it concerns. A `--check` flag makes the
invocation report a non-zero exit status when any diagnostic is present (for
CI); without it the overview always exits successfully, since it neither builds
nor manages state (§16.9). `--check` never changes what is rendered — only the
exit status.

The overview and the single-profile view report the profile's **compiler cache**
alongside its toolchain: the resolved launcher, or that caching is off /
unavailable / not enabled automatically (`auto` on an MSVC-style compiler,
§1.3.2 — rendered `auto (off for MSVC-style)` with a pointer to the
compiler-cache help topic, §16.31), mirroring the editor's `Cache:` row
(`spec/ui.md`). Cache **usage
statistics** (hit rate, size) are **off by default** — reading them spawns the
cache tool, a cost the read-only overview must not pay implicitly — and are shown
only under an explicit `--cache-stats` flag, which runs the tool's own stats
query for the profile's resolved launcher and folds the result into the report.
When no launcher is resolved, `--cache-stats` reports that there is nothing to
query rather than erroring; with **no active profile** (or an active profile
without a C/C++ project) it prints a one-line reason instead of nothing.

The overview also renders the **suggestions** count line (`spec/ui.md` §1.1) when
the suggestion framework has findings — a one-line advisory pointing at
`lw health` (§16.31). Suggestions are advisory: they never change the overview's
exit status and are independent of `--check`.

### 16.19 Convention migration

Recommended shapes for the workspace files change over time while older
shapes remain valid to read — the data model MUST keep resolving what it
resolved before. A management host (§16.9) therefore offers an explicit
**migration** operation that rewrites the workspace files from a still-valid
older shape into the current recommended one, changing form and never
meaning: a migrated workspace resolves to the same projects, configurations,
options and build types as before.

Migration is a set of named rules, each able to report what it would change
without changing it. The operation MUST:

- **Report before it writes.** Every rewrite is shown as its before and after,
  attributed to the rule that produced it. A non-interactive invocation
  requires explicit consent (§16.9 — it is a management write, never part of
  a build).
- **Refuse where it cannot preserve meaning.** A case a rule cannot rewrite
  without risking a change in behaviour is reported and left alone, never
  guessed at. Examples: a declared value with no equivalent to migrate onto,
  or a rewrite that would reorder an inheritance chain and so change which
  value wins.
- **Be idempotent.** Running it on an already-migrated workspace changes
  nothing and reports nothing pending.
- **Offer a check mode** that reports pending migrations and signals, through
  its exit status, whether any remain — so a project can keep its files from
  drifting back without granting write access.

Because the published snapshot is regenerated from the working copy (§2.4), a
migration that changes published items rewrites that snapshot wholesale rather
than patching it in place.

### 16.20 Module acquisition

Per §16.8 the set of modules available to a host is host-determined. A
**management host** (§16.9) MAY extend that set by acquiring additional module
implementations from a **curated index** — a listing, published through a
trusted channel, of the modules available for acquisition and, for each, where
to obtain it and the content hash of that artifact.

Acquisition is a management operation (§16.9), never part of a build: it is
performed only on direct invocation, and a read-only / CI build neither
triggers nor requires it.

The operation MUST:

- **Verify by pinned hash.** The acquired artifact is checked against the
  content hash the index records for it before any of its Lua is installed; a
  mismatch aborts the acquisition and installs nothing. The trust anchor is the
  index, obtained through a trusted channel, and not the artifact host —
  mirroring §16.12/§16.15, where provenance is anchored to something other than
  the served artifact itself.
- **Enforce the interface-version gate at acquisition time.** A module package
  declares the plugin-interface version it implements (§8.0); the index records
  that version so an incompatible package is refused *before* download, with a
  message distinguishing "update the host" from "the module has no compatible
  release yet." This is the same strict-equality rule the host applies when
  loading a module (§8.0), applied earlier so the failure is not deferred to
  first build.
- **Install out-of-band of the release source.** An acquired module is placed
  where the host resolves it alongside system Lua (§16.11) but separate from the
  release bundle, so that acquiring, updating, or removing a module never
  disturbs the verified bundle chain (§16.12–16.13), and a host self-update
  never disturbs acquired modules. A module package contributes its module
  implementation and any providers it brings (SDK providers, progress parsers,
  and the like); all become resolvable to the host together, exactly as if the
  host had shipped them.
- **Support update and removal.** A module may be updated to the version the
  index currently records, or removed. A bulk update skips any module the index
  lists as incompatible with the running host, reporting it rather than failing
  the whole operation — one stale module does not block the rest.

Acquisition applies to the standalone host. In an editor host, modules arrive
through the editor's own plugin mechanism (§16.8); the index is informational
there.

### 16.21 Repo-local launcher and version pin

A repository MAY commit a **launcher and version pin** so that contributors and
CI run a fixed, verified host without a prior global install. Three files at the
repository root carry this: a POSIX launcher, a Windows launcher, and a **pin**.
Downloaded host binaries and the provisioned bundle (§16.22) live under a
machine-local cache directory that is ignored by version control, so nothing
fetched is ever committed.

The pin declares a release **version** and, for every host binary and for the
release bundle, the **content hash** of that artifact. It is a trivially
parseable key/value list (not JSON) so a launcher can read it with a system
shell alone — one `version` entry, one hashed entry per host binary keyed by the
binary's asset identity, and one hashed entry for the bundle. The pin carries a
version and hashes **only, never a location**: the download origin is fixed by
the host and overridable solely by the user's environment or host configuration,
never by repository content (§16.23).

### 16.22 Launcher behavior and pinned-release provisioning

A launcher selects the host-binary asset for the current operating system and
architecture, reads the pinned version and that asset's hash, and — unless the
binary is already cached — downloads it from the fixed origin, verifies its hash
against the pin, and executes it, forwarding all arguments unchanged. A platform
for which the pin names no binary is an error, never a fetch of a different
platform's asset. Hash verification against the pinned hash is **mandatory and
unconditional**. Transport (TLS) verification of the download MAY be relaxed —
for an intercepting proxy — precisely because integrity does not rest on the
transport (§16.12) but on the independent, mandatory hash check; relaxing the
hash check is never permitted. A launcher MAY additionally run a stronger
provenance check when that tooling is present, and MUST degrade gracefully —
with a note, not a failure — when it is absent.

Because a host binary carries only the runtime bootstrap and not the behavioral
system Lua (§16.11), a host running in **pinned context** — launched by the repo
launcher, or re-exec'd by the redirect (§16.23) — MUST **provision** the pinned
release's bundle before it resolves system Lua: acquire the bundle for the pinned
version, verify it against the pinned bundle hash, and extract it to a
**repo-local** location under the machine-local cache directory, then resolve
system Lua from there rather than from any machine-global install. Provisioning
is idempotent: an already-extracted, matching bundle is reused without
re-downloading, and a failed or partial provision leaves any prior state intact
(§16.13). Keeping the bundle repo-local makes a pinned run reproducible — host
and bundle are the same pinned version — and leaves the machine-global
installation (§16.13) untouched. The trust anchor for provisioning is the
**committed pin hash**: the pin reached the runner through the repository, a
trusted channel, consistent with §16.15/§16.20 anchoring integrity to something
other than the served artifact.

A launcher never downloads or extracts the bundle itself — it fetches and execs
only the host binary, and the exec'd host self-provisions the bundle as above,
so the launcher depends on nothing beyond a system downloader and a hash tool.

### 16.23 Global pin-aware redirect

A globally-installed host, invoked for a **workspace operation** (build, run,
test, configure, clean) inside a repository that carries a pin, MUST honor the
pin. It resolves the pinned version from the workspace root — the same root
discovery that locates the workspace files (§2). When the pinned version equals
the running host's own release version it runs the operation **in-process**: no
download and no redirect (the fast path). When they differ it MUST acquire and
verify the pinned host binary, provision the pinned bundle (§16.22), and
**re-exec** the pinned binary with the same arguments, so the operation runs
under exactly the pinned release.

Redirection applies only to workspace operations. **Host and management
operations** — reporting the host version, self-update, install, and the pin
operations (§16.24) — MUST NOT redirect; they always run as the invoked (global)
host, so that, for example, updating the pin is never carried out by the old
pinned version. Redirection MUST be guarded against recursion: once a host is
running as the pinned version with the pinned bundle loaded, it never redirects
or re-provisions again (a sentinel carried across the exec).

The redirect has explicit **escapes**, all caller-owned: a *no-pin* flag runs
the invoked host with no redirect; an environment override naming a host binary
runs that binary and bypasses the pin entirely (the development / test-at-head
path); and a development source (§16.11) likewise bypasses. The first redirect or
provision of an invocation emits a one-line notice rather than stalling silently.

The following invariants are normative:

- **Fixed origin.** The download origin is fixed in the host, overridable only
  by a user-set environment value or host configuration, never by repository
  content.
- **Version-and-hash pin, never a location.** A repository cannot redirect the
  fetch; it can only name a version and the hashes the fetched artifacts must
  match.
- **Mandatory hash match.** Verification of every fetched artifact against its
  pinned hash is unconditional — never waived, including when transport
  verification is relaxed for a proxy (§16.22). An artifact whose hash does not
  match the pin aborts the operation and is discarded.
- **Never execute repository scripts.** The global host MUST NOT execute a
  repository-provided launcher script. It resolves the pin **declaratively** and
  runs the official binary it fetched and verified itself; auto-running a
  repo-provided script would be an arbitrary-code-execution vector.
- **Bounded residual risk.** A malicious pin can at worst force acquisition of an
  authentic but **older / downgraded** official release; it cannot introduce
  unofficial code, because every fetched artifact must match a hash the host
  obtained from the fixed origin. Provenance anchored outside the project's
  infrastructure (§16.15) applied at redirect time is possible future hardening.

### 16.24 Pin management: bootstrap and update

Two **management operations** (§16.9) maintain the launcher and pin; being
management, they never redirect (§16.23).

**Bootstrap** installs the launcher scripts and the pin into the repository —
defaulting to the running host's release version, or an explicit version — and
populates the pin with the content hashes of every host binary and of the bundle
for that release. It appends the machine-local cache directory to the
repository's ignore file idempotently, creating that file if absent, and never
rewrites or discards unrelated ignore content. Re-running it MAY refresh the
scripts and pin, but MUST NOT silently destroy user edits.

**Update** rewrites the pin to a target version — explicit, or the latest release
— fetching that release's hashes; it MUST validate that the target release is
fetchable before writing, failing cleanly otherwise, and refreshes the launcher
scripts when their format has changed.

Both obtain the per-artifact hashes from the release's **signed** hash list
(§16.15) and verify that signature before trusting any hash, so the pin's
committed hashes are themselves anchored to the release key at authoring time.
Runtime provisioning (§16.22) then trusts the committed pin hash directly, since
the pin has itself reached the runner through the repository.

### 16.25 Working-copy pull across checkouts

The working copy (§2.2) is machine-local and version-control-ignored, so a fresh
checkout — most commonly a linked git worktree — starts with no working copy and
therefore no profiles, configuration sets, or projects to build. A **management
operation** (§16.9) MAY **pull** another checkout's working config into the
current one, so a new checkout inherits a ready-to-build configuration without
re-authoring it.

Pull is a management write (§16.9): it authors the current working copy only,
never the published snapshot (§2.4) and never any build or cache state (§2.3).
It is never part of a build.

**Source resolution.** The source is another checkout directory. Absent an
explicit source, the operation resolves the **main worktree** of the current git
worktree — the same read-only, time-bounded detection the status hint uses
(§16.18). Resolution is explicit and never guessed (§16.3): if no source is
given and the current directory is not a linked worktree, the operation errors
and asks for an explicit source; a source that resolves to the current checkout
itself is refused; and a source that holds no working copy is reported as having
nothing to pull.

**What is pulled.** The source's shared configuration items: its projects (with
their configurations, launch configurations, deploy steps, and variables), its
configuration sets, its profiles, its declared toolchains (§10.1), its per-profile
default targets, and its workspace-level integration settings (debugger-adapter
and language-server option maps). When the source's working config is internally
consistent, every cross-reference a pulled item makes (a configuration set to its
projects and configurations, a profile to its set) resolves against the pulled
result. Pull propagates configuration but does not itself validate references — a
source that already contains a dangling reference produces one in the target too.

**What is excluded.** Three pieces of working-copy state are **per-checkout** and
never pulled — the target keeps its own: the **active-profile selection** (§4.2),
the **workspace name** (each checkout keeps its own identity — pulling it would
silently alias one checkout as another), and any **per-machine device selection**
(§12), which is the same category of local choice as the active profile. Build and
cache state (§2.3) is not part of the working copy and so is never involved.

**Merge semantics.** The pull is a **non-destructive, item-level union in which
the source wins on collision**: an item present only in the current checkout is
preserved; an item present in both is replaced by the source's version; an item
present only in the source is added. This is deliberately the opposite winner
from the published-snapshot fold (§2.4), where the working copy wins so external
changes never clobber local edits — here the caller is explicitly asking for the
source's configuration. The workspace-level integration settings are the one
exception to whole-item replacement: they are **unioned key by key** (source wins
per key), so pulling one debugger adapter or one language-server option keeps the
target's sibling entries rather than dropping them. When the current checkout has
no working copy at all, the pull creates one from the source's config in full.

Pull writes the working copy through the same atomic, non-clobbering path as any
other management write (§2.3), and reports what it added, updated, and kept. It
MAY offer a **preview** mode that reports the same plan without writing.

### 16.26 Worktree listing

Because a working copy is machine-local and per-checkout (§2.2, §16.25),
configuration commonly lives in one checkout while a sibling git worktree has
none. A host MAY **list the worktrees** of the current git repository so the
user can see, before pulling (§16.25), which checkouts already hold a workspace.
The listing is read-only: it inspects no build or cache state and authors
nothing.

For each worktree the listing reports its path, its checked-out branch (or that
it is a detached HEAD or a bare entry), which entry is the repository's **main
worktree** and which is the **current** one, and whether loomworks is
**initialised** there — the same presence test used elsewhere: a workspace is
present when the published snapshot (§2.4) or the working copy (§2.2) exists at
that checkout. The set of worktrees and their order come from the same
read-only, time-bounded git detection the status hint and pull use (§16.18,
§16.25); the main worktree is the first entry.

Unlike the status hint — which treats git as a best-effort convenience and
degrades silently when it is absent (§16.18) — worktree listing is **inherently
git-based** and therefore reports an explicit error, with a non-zero status,
when git is unavailable or the current directory is not within a git repository,
rather than producing an empty or misleading list (§16.3). A request for a
sub-operation the host does not recognise is likewise an explicit error, not a
silent fall-through to the listing.

### 16.27 Worktree creation

Because a fresh checkout starts with no working copy (§16.25), the two steps a
user takes to begin work in a sibling worktree — create the git worktree, then
pull the existing configuration into it — are a single common motion. A host MAY
offer a **worktree-creation operation** that performs both: it creates a git
worktree for a named branch and then, by default, pulls the main checkout's
working config (§16.25) into the new worktree so it is immediately buildable.

**Placement.** The new worktree is created under the repository's **main
worktree** — the same first-entry detection listing and pull use (§16.26,
§16.25) — so the operation works when invoked from any worktree and the result
always registers under the main repository. The branch identifier is reflected
into the worktree's location in full, so a hierarchically-named branch produces
a correspondingly nested directory rather than a flattened one.

**Branch handling.** When the named branch does not yet exist it is created —
from an explicit start point if given, otherwise from the main worktree's
current commit — and the created branch carries the full name as given, never a
truncated or last-segment form. When the branch already exists it is checked out
into the new worktree; a branch already checked out in another worktree is a git
constraint the operation surfaces as an explicit error (§16.3) rather than
working around.

**Git-required and non-destructive.** Like listing (§16.26) the operation is
inherently git-based: an absent git or a non-repository directory is an explicit
error with a non-zero status. It is a mutation but never a deletion (§2.3, §16.9)
— it creates a worktree and authors the new checkout's working copy, and it MUST
NOT overwrite or remove existing files: a target location that already exists is
refused rather than clobbered.

**Auto-pull is best-effort over a committed worktree.** The pull step follows
§16.25 exactly (source-wins, non-destructive, item-level, excluding the
per-checkout state). A main checkout that holds no working copy is simply
"nothing to pull" and not a failure. If the worktree is created but the pull
then fails, the worktree is **kept** — undoing it would be a deletion — and the
operation reports the partial success (worktree created, pull to be re-run by
hand via §16.25) with a non-zero status so the incomplete state is visible. A
mode that **skips the pull** and creates the worktree alone MAY be offered.

### 16.28 Output-artifact conflicts

Two config units **conflict** when their **resolved artifact sets** (§5.9 — the
absolute on-disk artifacts a configured unit produces, reported by the module's
`resolve_artifacts` capability, §8.4) overlap on at least one path. This is
distinct from the shared-build-directory lock (§16.6): that serializes
*concurrent* operations on *one* build directory, whereas a conflict is
*sequential* clobbering of a *shared output path* by units in *different* build
directories — the case where two profiles differ only by toolchain yet a
hardcoded output location makes them emit the same binary.

A headless **build** of unit U is **refused** when building U would overwrite an
artifact currently owned by another **built** (fresh) unit V — i.e. U and V
conflict and V is in the `built` state. The refusal is a precondition failure
(§16.7): non-zero exit, and a message naming the conflicting **profile** and the
shared artifact **path**, and stating that `--force` overwrites it (marking V
**overwritten**/stale, §5.9). Consistent with every other build-precondition
refusal (§16.9 blank-variable gate, §16.6 lock loser), the exit status is **1**.

The refusal is **self-limiting**: forcing the build transitions V to
overwritten/stale, so V no longer counts as a fresh `built` owner (§5.9) and a
subsequent build of U no longer conflicts — a user is blocked at most once per
switch back to a still-fresh conflicting profile.

`--force` overrides the refusal for that invocation only — it is **transient**,
never recorded as an acknowledgement that the two units may share output. It
does not weaken any other gate.

Conflict detection is **unknown-until-configured**: a unit's artifact set is
known only once it is configured (§16.18 mirrors this for target listing). A
unit that is not yet configured has no known artifacts and so is never the V
that blocks a build, and never the U that is blocked — the system reports what
it knows and never guesses an artifact path (§16.3). A module that reports no
artifacts (`resolve_artifacts` absent or empty — e.g. the shell module, which
has no targets) contributes nothing to the index, so its units are never in a
conflict; this is graceful degradation, not a special case (§8.4).

Under `--no-interaction` the refusal is **never a prompt**: the build simply
declines with exit 1, exactly as the blank-variable gate does (§16.9). Forcing
in a non-interactive run is possible only by passing `--force` explicitly. In an
interactive editor host the same conflict is surfaced through a confirmation
dialog rather than this flag (see [`spec/ui.md`](../ui.md) §1.5, §1.8).

### 16.29 Update channels

The **release source** (§16.11) is resolved from an **update channel** — a
named track of releases the host self-update follows. The system defines two:

- **stable** (default) — the newest **full release**, excluding pre-releases.
- **unstable** — the newest release **including pre-releases**, for testing
  ahead of a stable cut.

A channel governs only *which* release an un-pinned acquisition (§16.13)
resolves to; it changes nothing about *how* that release is trusted. Every
channel's releases are acquired through the identical integrity chain (§16.12,
§16.15): the manifest MUST verify and every artifact hash MUST match, on
unstable exactly as on stable. "unstable" denotes release maturity, never
reduced verification — an unverified or hash-mismatched bundle MUST NOT execute
regardless of channel.

Channel selection is a host concern with precedence: an explicit per-invocation
override, then host configuration, then the default (stable). A pin (§16.21) is
independent of and takes precedence over channel resolution: a pinned
invocation acquires exactly the pinned version+hash and consults no channel. An
explicit release-source location override (a mirror) likewise supersedes
channel resolution, which applies only to the default origin. When such an
override supersedes an explicitly-requested **non-default** channel, self-update
MUST warn that the channel was ignored — the supersede is by design, but it MUST
NOT be silent, or a user who selected a channel will believe it took effect. (A
default-channel selection under an override is no conflict and warns nothing.)

A pre-release version orders **below** its corresponding full release: version
comparison used for activation, "already newest," and cache reclamation
(§16.13) MUST treat a pre-release as older than the release it precedes — so
following stable never selects or retains a pre-release over its release, and
switching channels does not misrank installed bundles.

### 16.30 Headless reset

A headless **reset** hard-resets build state: it removes a profile's build
directories from disk (a full recursive delete, not the build system's own
artifact clean of §16.1) and returns the affected units to the **unconfigured**
state (§3), so the next build (§16.4) reconfigures from nothing. It is the
headless equivalent of the editor's per-profile delete, minus removing the
profile: the profile, its configuration set, and its toolchain pins are left
intact and buildable — only cached build state is discarded. Reset is therefore
distinct from clean (§16.1), which keeps the configuration and only removes
artifacts.

Scope is a single profile (resolved per §16.3), or — with an explicit
all-scope flag — every build directory the workspace knows, across all
profiles and including **orphaned** directories (cached build state no profile
references any longer). A profile with no configured build directory resets
nothing and succeeds.

Reset obeys the same directory-safety rules as every other deletion path: a
build directory is removed only when it lies within the workspace root, and a
directory still referenced by another unit not part of the reset is **retained**
on disk (its state cleared for the reset units only) rather than deleted out
from under the reference. Reset is exclusive, acquiring the per-build-directory
lock (§16.6) for its directories so it cannot race a concurrent build.

Because reset destroys build state that a build would otherwise reuse, it
**requires confirmation**. An interactive host prints the directories that will
be removed and prompts before acting; a confirmation flag skips the prompt. In a
non-interactive host (§16.3) the confirmation flag is **mandatory** — without it
reset refuses with a message naming the flag, rather than deleting unprompted.
This is the destructive-management posture of §16.9: it authors nothing in the
working copy, but it does discard cache and on-disk state, so it never proceeds
silently. Reset reports success only after confirming the targeted directories
are **actually gone from disk** — the removal subprocess exiting is not by itself
proof (a directory can briefly persist after deletion, or a removal can fail), so
a directory that is still present once the removal settles is reported as a
failure rather than reported as removed. On success the removed directories are
reported and the exit status is **0**; on any failure the reason is reported and
the exit status is non-zero.

**Concurrent editor.** Reset is designed to run while an editor host is live on
the same workspace, and coexistence rests on the same three-file/cache
reconciliation and the same per-build-directory lock the rest of the system
uses — reset introduces no private channel:

- *In-progress editor build.* A build/configure/clean holds the cross-process
  build-directory lock (§16.6) for its directory. Reset acquires the **same**
  lock for every directory it would touch **before** removing anything, and
  acquisition is fail-fast: if the editor is mid-build on any target directory,
  reset removes nothing and exits non-zero, naming the holder — it can never
  rm a directory a build is using. Conversely, once reset holds the lock, the
  editor's build of that directory fails to acquire and declines, so neither
  side deletes or writes a directory the other is operating on.
- *Reload to unconfigured.* Reset's cache rewrite is an ordinary external change
  to the cache file; the editor's file reconciliation observes it and remerges,
  so the reset units surface as `unconfigured` without any manual reload. No
  build state survives the reset for the editor to act on.
- *Mid-deletion crash-safety window.* Reset marks the cache `unknown` **before**
  removing a directory and clears the entry only after the removal succeeds
  (§4.6). An editor that reconciles inside that window reads `unknown` for a
  directory that is vanishing; the missing-directory downgrade (§3.1 rule 7)
  **exempts** `unknown`/`deleting`, so the editor does not reset such a unit to
  `unconfigured`, and a build against an `unknown` unit stays blocked — the
  editor cannot race the deletion. This exemption is keyed on the on-disk cache
  state, so it holds across processes, not only within the deleting one.
- *Post-reset stale in-memory state.* Between reset finishing and the editor's
  next reconciliation, the editor may still hold an in-memory `built`/`configured`
  unit pointing at a now-deleted directory. The build gate re-checks directory
  presence with a **live** stat (§3.1 rule 7), so a build initiated in that
  window is forced to reconfigure into a fresh directory rather than run the
  build tool against a deleted one.
- *Owned LSP database.* The active profile's build directory holds the
  compilation database (e.g. `compile_commands.json`) an LSP server consumes
  (§9). Removing it degrades gracefully: database resolution treats an absent
  file as "no database" rather than pointing the server at a missing path, and
  the next configure regenerates it, at which point the server reattaches. No
  server restart is required of reset itself.

### 16.31 Headless health and suggestions

A headless **health** report lists the workspace's **suggestions** in full — the
detail behind the compact `N suggestions` line that the status overview (§16.18)
and the editor status page (`spec/ui.md` §1.1) show. Health is read-only: it
performs no build and authors nothing (§16.9).

Suggestions come from an **extensible suggestion-provider framework**. A provider
inspects the resolved workspace and returns zero or more items, each a
`{ title, detail, remedy }` triple: `title` is the one-line summary, `detail`
explains why it fires, and `remedy` is the concrete action the user can take.
Providers are advisory only — an item never gates a build, never fails
`--check` (§16.18), and is distinct from a **diagnostic** (a structural problem
that does gate operations). The framework is the general surface; individual
providers ship independently, and the health report aggregates whatever providers
are registered.

**Actionable vs informational items.** An item is one of two **kinds**. An
**actionable** item is a nag: something the user can act on, carrying a `remedy`.
An **informational** item affirms a healthy state (for example, that a compiler
cache is in use) and carries no remedy. Both appear in the full health report, but
only actionable items contribute to the compact `N suggestions` count (§16.18,
`spec/ui.md` §1.1) — an affirmative note never inflates the nag total. The report
renders informational items distinctly (as positive status, not a warning).

**Provider #1 — compiler cache.** When the workspace has one or more C/C++
projects (a project whose module reports the caching-relevant language), the
provider gives a **one-line verdict** — a title and, for an actionable item, a
short remedy; the explanations (why `auto` is off for MSVC-style compilers, how
to opt in, the debug-information adjustment and the post-configure scan, tool
configuration through the environment, the not-applied cases, per-platform
install commands, reconfigure behavior) live in a **help topic** the items point
at (`lw help cache`, also reachable as `lw help sccache` / `lw help ccache`).
Health must **never claim a cache is in use** when the build would not use it.

With an **active profile** that has a C/C++ configuration, the item reflects
**that profile's resolved cache status** — the same resolution its `Cache` row
shows (§16.18), so the health report never contradicts the status overview:

- its effective policy is `off` → nothing (the user opted out for that
  configuration, as below);
- its C/C++ configuration is one the module **cannot apply** a launcher to (§8
  `cache_launcher_applicable` returned `false`) → an **informational** item,
  "Compiler cache not applied (`<reason>`) — lw help cache", whether or not a
  launcher is installed (installing one would not help);
- its launcher **resolved** → **informational** "Compiler cache: using `<tool>`";
  when the recorded compatibility scan found compiles that launcher will FAIL
  for the profile's units, the affirmation is qualified in the same line
  ("… — but it will fail N compiles (lw help cache)") so it never reads as
  contradicting the finding reported next to it;
- its policy names a launcher explicitly (`cache=<tool>`) that is **not found**
  → **actionable** "`cache=<tool>` set but `<tool>` not found" (remedy: install
  it — `lw help cache`), never a "using" item for some other launcher;
- a compiler cache is present but the configuration uses an **MSVC-style**
  compiler under `auto` (§1.3.2: no launcher) → **informational** "`<tool>`
  available — not enabled for MSVC-style (lw help cache)";
- otherwise → **actionable** "No compiler cache found", whose remedy names the
  platform-customary launcher (`sccache` on Windows, `ccache` on Linux/macOS —
  an install recommendation only, not the `auto` preference, §1.3.2) and, for an
  MSVC-style compiler, that it must then be opted into.

With **no active profile**, every profile that has a C/C++ project is evaluated
through the same resolver (its own `Cache` status):

- every such profile resolves `off` → nothing;
- some profile resolves a launcher → **informational** "Compiler cache: using
  `<tool>` (`<profiles>`)", naming the profiles that would use it — qualified
  the same way ("… — but it will fail N compiles (lw help cache)") when the
  recorded scan found compiles that launcher will fail in those profiles' units;
- otherwise, a profile's explicit `cache=<tool>` is not found → the
  **actionable** not-found item, naming the profile;
- otherwise, a launcher is present on the toolchain path → **informational**
  "`<tool>` available — not enabled (lw help cache)" (with "for MSVC-style" when
  a profile is MSVC-style under `auto`); with no profiles at all, "`<tool>`
  available (lw help cache)";
- otherwise → the **actionable** install item as above.

A **cache-compatibility finding** recorded by the post-configure scan (§5.1, §8
`cache_compat_scan`) for a unit of the active profile — or, with **no active
profile**, of any profile (consistent with the no-active-profile evaluation
above; a unit shared by several profiles is reported once) — gives an
**actionable** item per affected configuration: `title` states that the applied launcher will
fail (severity `"error"`) or cannot cache (severity `"warning"`) some compiles,
`detail` lists the affected groups (target or directory) with the offending
option and unit counts (a pervasive finding collapsed to one line, §8), and
`remedy` is one line naming both ways out — switch those compiles to a
cache-compatible option (module specs; for a pervasive finding, remove the
directory-wide option) or turn caching off with the command for the mechanism
that enabled it (`lw profile set <profile> <project> cache off` for a profile
fill, `lw config set <project> <configuration> overrides.<family>.cache off` for
a compiler-family override, `… variables.cache off` for a configuration
variable, §8) — and the help topic. A scan that
was **skipped** for lack of compile-command data yields an **informational**
item saying the check was skipped for that configuration (detail: why), so a
clean report is never mistaken for a verified one. The findings reported are
those of the build's **current** compile data, not merely of the last
configure: the build tool may re-run the generator itself (e.g. after a
build-system file edit) and add or remove the offending option without any
configure, so before reporting, a recorded result whose module stamp of the
scanned data changed is **re-scanned** (§8 `cache_compat_stamp`) — locally, from
the existing post-configure metadata, spawning nothing. This refresh is in
memory: health never writes the build-state cache (the next build's result
recording persists the refreshed result).

The provider is silent (neither affirms nor nags) when the workspace has no C/C++
project, or when every C/C++ project has pinned `cache` to `off`, since the user
has opted out. It reads only already-resolved workspace state and the
toolchain-path index; like the rest of introspection it does **not** spawn the
cache tool. Cache usage statistics remain behind the explicit `--cache-stats` flag
of the status overview (§16.18), not the health report.

This provider is **workspace-scoped** — it needs a resolved workspace and
contributes nothing without one (below).

**Passive vs on-demand providers.** A provider is one of two kinds. A **passive**
provider is side-effect-free and cheap — it reads resolved state only, never
spawns a tool and never touches the network (the one local read beyond resolved
state is the cache-compatibility re-scan above, of existing post-configure
metadata, and only when its stamp changed — which also invalidates the cached
tier, so it happens once per change) — and so contributes to *both* the
frequently-rendered `N suggestions` count (§16.18, `spec/ui.md` §1.1) and the
full health report. An **on-demand** provider is permitted a network call or
other expensive/one-shot check; it runs **only** when health is explicitly
invoked and is deliberately excluded from the passive count. This split is a
hard requirement: a passive status render MUST NOT perform network I/O. Provider
#1 (compiler cache) is passive; the update-availability provider below is
on-demand.

**Cached two-tier model.** Because passive detection is no longer free — even a
passive provider may probe the toolchain path, and the provider set grows over
time — the suggestion results are cached so the frequently-rendered
`N suggestions` count does not repeat the work on every render. The cache is a
small workspace-local file, separate from and independent of the build-state
cache (its own schema, versioned on its own): it is an internal advisory cache
under the workspace's `.nvim/` directory, never a project or build-system file,
so "health authors nothing" (§16.9) continues to hold. It records two tiers:

- a **local tier** — the results of the passive (workspace-scoped, local-detection)
  providers — stored with the time they were computed and an **invalidation key**:
  a cheap fingerprint of the inputs those providers read (the projects and their
  cache policy, the resolved tool selection, the platform, the recorded
  post-configure cache-compatibility results, and — for each unit with such a
  result — the module's **current** stamp of the data that scan read (§8
  `cache_compat_stamp`; one stat or directory listing per cache-enabled unit,
  never a decode), so a generator re-run by the build tool invalidates the tier
  and the passive count never keeps a stale finding). The key is taken from the
  results **as recorded** before the providers run, so an in-memory refresh a
  provider makes (and does not persist) does not invalidate the tier again in
  the next process. When the fingerprint changes, the local tier is stale;
- a **network tier** — the results of the on-demand (network-backed) providers —
  stored with the time they were computed and a **running-version key** (the
  running release bundle, the running host binary's release identity (§16.32) and
  the effective update channel, all read locally), and governed by a
  **time-to-live** (on the order of a day). Items recorded under a different
  running-version key (e.g. before a self-update) describe a release that is no
  longer running and are stale regardless of age.

A third, **inventory** tier holds the environment inventory's probe results; it
is written only by a health run and read, never recomputed, by a passive collect
(§16.33).

The two refresh tiers, over that one cache, are:

- **Passive collect** (the `N suggestions` count of §16.18 and `spec/ui.md` §1.1,
  and the editor status page) reads the cache. If the local tier is absent or its
  invalidation key no longer matches the current inputs, it **recomputes the
  passive providers**, rewrites the local tier, and uses the fresh result — a
  lazy, compute-on-first-use that stays cheap on every subsequent render. It
  **never** computes the network tier: it includes whatever network-tier items
  the cache already holds for the current running-version key (informational,
  however old — so a finding surfaced by a prior health run is still reflected in
  the count; items recorded for another running version are dropped) but performs
  no network I/O.
  This preserves the hard invariant that a passive render never touches the
  network.
- **On-demand health** (`lw health`) is the full refresh. It **always** recomputes
  the local tier, and recomputes the network tier when the cached network tier is
  older than its TTL, was recorded under a different running-version key, or the
  user forces a refresh; otherwise it reuses the
  cached network tier, so back-to-back health runs do not repeatedly hit the
  network. It rewrites the cache and reports every item.

**First run and resilience.** With no cache present, a passive collect computes
only the local tier (never the network), and a health run computes both. The
cache is advisory and self-healing: a missing, corrupt, or older-schema cache is
treated as empty and recomputed — it never raises an error and never blocks a
render or a health run. Writes are atomic. A passive collect outside a workspace
(no `.nvim/` to key against) simply runs the passive providers directly without
caching, and a health run outside a workspace runs its workspace-independent
providers directly (the local tier has nothing to key or store). No background or
asynchronous network refresh is implied — the network tier is refreshed strictly
on an explicit `lw health`.

**Provider #2 — update availability (on-demand).** When the host is running a
versioned release (a source with a comparable version — not a development/fused
source, and not the in-editor plugin, neither of which self-updates through the
CLI), this provider resolves the newest release available on the **resolved
update channel** (§16.29) and, when that is strictly newer than the running
version, suggests updating. Its `title` is "Update available", its `detail` is
`<current> → <newest> on the <channel> channel`, and its `remedy` points at the
self-update command — except in a **pinned** context (a repository version pin,
§16.21–16.24: the pinned launcher's sentinel is set, or the running bundle is the
repo-local pinned copy), where the pin owns the version and self-update would not
change it; there the remedy points at the pin-management update command (which
moves the pin to the newest release). Version comparison is the same semver-aware ordering used
for activation (§16.29), so a pre-release never reads as "newer" than the full
release it precedes.

The same check covers the **host binary** (§16.32), which can be left stale while
the bundle is current (an unwritable install location, a bundle-only update, or a
host from before host self-update existed). Against the same newest release, and
upgrade-only by the same rule host self-update applies (§16.32):

- a host that self-update **would replace** — its embedded release version is
  strictly older than the newest, or it is a release host with no embedded
  version — gets an **actionable** item "lw binary `<running>` is older than
  `<newest>`" (`<running>` reads "(unknown release)" for an unversioned release
  host), remedy: run the self-update command (with the help-topic pointer);
- a host from **before host self-update** (whose bootstrap cannot replace itself)
  gets an **actionable** item "lw binary predates self-update — reinstall once
  (see README)", remedy: reinstall the host once as the installation
  instructions describe;
- a **development build** (the same predicate self-update and the version report
  use, §16.32), a **pinned** host (the pin owns its version, §16.24), or a host at
  or newer than the newest release → no host item.

When the bundle is also stale, one "Update available" item suffices — the
self-update it points at replaces a self-updating host too — except for a host
from before host self-update, whose item is still reported. Reading the host's
release identity is local and network-free; only the newest-release resolution
above touches the network, so the host check shares this provider's on-demand
tier and silent degradation.

Resolving the newest version is a **network** operation (the releases API for
`unstable`, otherwise a lightweight read of the channel base's manifest to learn
the version it names — never a bundle download, and this availability probe
applies no integrity verification; a real self-update still verifies signature +
hash per §16.12). Because it is network-backed it is on-demand: it never runs on
the passive `N suggestions` count. It degrades **silently** — an offline host, an
HTTP/API error, an unknown channel, or an already-current version all yield *no*
suggestion and no error output. The network-derived version is validated before
it is displayed and is never interpolated into a URL or path.

**Channel override surfaced.** When a release-source location override (a mirror
— `LOOMWORKS_RELEASE_URL` or the `release-url` setting) is in effect *and* a
non-default channel is configured, health reports that the override **supersedes**
the channel (§16.29): the configured channel is effectively ignored, updates
come from the override. This item is network-free (it reads only the resolved
override + channel) but is surfaced in the health view rather than the passive
count. It is the health-view counterpart of the inline self-update warning for
the same state; both derive from the identical override/channel resolution
rather than duplicating it.

**Health runs without a workspace.** A provider is either **workspace-scoped**
(it inspects the resolved workspace — e.g. the compiler-cache provider) or
**workspace-independent** (it ignores the workspace — the update-availability and
channel-override providers, which concern the running `lw` release itself). When
health is invoked outside a configured workspace, the workspace-independent
providers still run and report; the workspace-scoped ones simply contribute
nothing. So `lw health` in a plain directory still surfaces an available update or
a channel override — it does not fall silent merely because no workspace is
loaded. The report leads with the same worktree/init hint the status overview
shows (§16.18) so the absence of project-scoped items is explained.

**Builds are unaffected and need no new flags.** A headless build honors the same
`cache` policy resolution and launcher staleness as the editor (§1.3.2, §5): the
launcher is resolved from policy, applied by the module, and reconfigured on
change through the ordinary build gate. No build-time flag turns caching on or
off — that decision lives entirely in the `cache` policy variable.

### 16.32 Host self-update

A host built from a release carries that release's **version identity**,
fixed into the binary when it is built. A host built from a working tree (a
development build) carries none. The version-reporting host operation reports
the host's release version alongside its capability version (§16.14), the
system-Lua source (§16.11), the active bundle, and the channel (§16.29). A
host with no release version never reports a guessed version: a development
build reports that it is one, and a release host with no version identity
(released before identity existed) reports its release as unknown. The
distinction uses the same development-build determination as host
replacement below, so a host reported as a development build is never
replaced and one reported as an unknown release is.

Because host-side behavior (argument handling, source resolution, the
acquisition procedure itself) lives in the host and not the bundle (§16.11),
a bundle update alone never delivers a host fix. **Self-update therefore also
replaces the host binary**, after the bundle acquisition (§16.13) succeeds or
finds the bundle already current (or finds that the release needs a newer
host, below), unless the caller passes an explicit *no-host* flag. The
replacement follows these rules:

- **Same release, same origin.** The host is taken from exactly the release
  the bundle acquisition resolved — through the same channel (§16.29) and the
  same release-source override — so host and bundle never come from different
  releases or origins.
- **A release that needs a newer host.** When the target release's bundle
  requires a newer host capability than the running host provides (§16.14),
  the bundle is not installed — but the release's signature-verified identity
  is still used as the host-replacement target, so raising the minimum never
  strands an installed host. If the host may replace itself (the rules below),
  it is replaced first and self-update then reports that the binary was
  updated and that self-update must be re-run to update the bundle, exiting
  with a non-zero status since the bundle is not yet updated. If the host step
  is skipped or fails, the original incompatibility error is reported together
  with how to install the required host manually, with a non-zero status.
- **Only when newer.** The host is replaced only when the target release's
  version is strictly newer than the running host's embedded release version,
  under the same pre-release-aware ordering the channels use (§16.29): a
  pre-release orders below its release. A target equal to the running host's
  version leaves the host as it is (already current); an **older** target —
  e.g. after switching from the `unstable` to the `stable` channel — is skipped
  with a note and never downgrades the host, just as the newest installed
  bundle, not an older one, is the one that runs. A running host with **no**
  embedded release version is treated as unknown and is replaced (every host
  released before version identity existed is such a host). A request to
  force re-acquisition of the bundle (§16.13) does **not** force a host
  replacement: the host is still replaced only under this rule.
- **Verified before swap.** The replacement binary is the platform's host
  asset (§16.22 asset selection), verified against the **signed** release hash
  list (§16.15): the list's signature MUST verify against the key carried by
  the running host, and the downloaded binary's hash MUST match its entry.
  A valid signature proves only that the list is *some* release's; the list
  MUST also be bound to the **target** release by naming that release's own
  version-bearing asset (its bundle, whose name carries the version), so a
  genuine older release's list — and its older host — can never be replayed
  for a newer target. A list without that entry is an integrity failure.
  This check is mandatory and unconditional — relaxing transport verification
  (§16.22) never relaxes it — and it completes **before** the installed binary
  is touched. A release whose hash list does not verify, is not the target's,
  or does not name this platform's asset, is never installed.
- **Atomic, never half-written.** The verified binary is staged next to the
  installed one and moved into place in a single step. Where the platform
  forbids replacing a running executable but permits renaming it, the running
  binary is first renamed aside and the new one moved into its place; the
  renamed-aside binary is removed, best-effort and silently, by a later
  invocation. Any failure at any step leaves the original binary installed and
  runnable — a rename-aside is rolled back.
- **Unwritable install location.** When the host's location cannot be written
  (a system directory, a package-managed install), self-update warns — naming
  the release asset and how to replace it manually — and otherwise succeeds:
  the bundle update stands and the exit status is 0. A failure to *obtain* the
  replacement (unreachable origin, a mirror without host assets) is likewise a
  warning, since the bundle update already succeeded; an **integrity** failure
  (hash list signature, a list that is not the target release's, or binary
  hash mismatch) is an error with a non-zero
  exit status.
- **Only a globally-installed release host replaces itself.** A host running
  from a repository's pinned-launcher cache or in pinned context (§16.21–16.23)
  never replaces itself — its version is owned by the pin. A development build,
  a host running a development source (§16.11), or the bare runtime used to run
  a source tree likewise never replaces itself. In these cases the host step
  is skipped with a note; the bundle behavior is unchanged.

Host replacement is a management operation (§16.9): it happens only on an
explicit self-update, never as part of a build or any workspace operation.
A host left stale — by an unwritable location, a no-host update, or because it
predates host self-update — is reported by the health update check (§16.31),
which applies these same replacement rules to decide whether to flag it.

### 16.33 Environment inventory

The health report (§16.31) also answers "is this machine ready?": an
**environment inventory** of every external thing loomworks knows how to use,
each reported **found** (with its version and location when known), **missing**,
or **unknown** (the probe failed or timed out — never guessed either way). Like
the rest of health it is read-only and authors nothing (§16.9): it installs
nothing and changes no selection.

**Contributors.** Core owns no knowledge of particular tools. The inventory is
the union of **declarations** from:

- **modules** — the build-system executables and toolchain installations they
  use (§8.4 `health_inventory`);
- **language-server integrations** (§9.3) and **debug-adapter integrations**
  (§8.9.6) — the servers and adapters they can drive, located through the
  filesystem and the executable search path only (never an editor-only registry
  API), so the report is the same in both hosts. Because an editor integration
  may need editor-only facilities at load, its declaration lives in a
  host-neutral **inventory companion** (§9.3) that both hosts discover;
- **SDK providers** — their detected installations (§10.1 `detect_all`) and any
  extra items they declare (§10.1 `health_inventory`);
- **core itself** — the running `lw` release (the facts the version report
  shows, §16.32), the compiler-cache launchers it resolves (§1.3.2), and the
  **plugin registry**: every module, SDK provider and integration found on the
  runtime path with its interface version, including any **rejected** one
  (interface-version mismatch or load failure, §8.0) with the reason.

A **declaration** is `{ id, category, label, probe }`, built by a hook that
receives a context carrying the host platform, an executable-search-path lookup,
an asynchronous process runner, and the workspace when there is one (so an SDK
declaration can enumerate the installations profiles pin). `id` is an opaque, stable
string; declarations with the same `id` describe the same thing (two modules
that use the same executable declare the same id) and are **probed once**.
`category` is one of a fixed, core-owned set that also fixes the report order:
*build tools*, *compilers*, *compiler caches*, *language servers*, *debug
adapters*, *SDKs*, *plugins*, *lw*; an unrecognized category renders under
*other*. `probe(ctx, done)` resolves to one or more **results** — an enumerating
declaration (every installed toolchain, every SDK installation) yields one
result per installation found, or a single `missing` result. A result is
`{ id, label, status = "found"|"missing"|"unknown", version?, path?, detail?,
hint? }`, where `hint` is a one-line, platform-appropriate install remedy or a
help-topic pointer — never a paragraph. A probe may spawn a version query or an
installation locator; probes run **concurrently**, each under a timeout, and a
probe that errors or times out yields `unknown` and never fails the report.

**Required vs other.** Inside a workspace the results are split into **Required
by this workspace** and **Other**, with nothing new for the user to declare:

- each module answers, for a project, its resolved tool and the configuration
  the profile maps, the inventory ids that project needs (§8.4
  `health_requirements`); a requirement may name the **enumerating declaration**
  that would have produced its result (`via`), so a requirement whose
  enumeration was inconclusive reads as unknown, never as missing;
- a profile that pins an SDK installation requires it (§10.4);
- a project whose module type is not loaded (missing or rejected) requires that
  module — its plugin-registry entry.

A workspace with no profiles at all scopes its requirements to every project
(with no tool), so a module's own executable is still required.

The requirement scope follows the compiler-cache provider (§16.31): the **active
profile's** projects and tools, or — with **no active profile** — the union over
**every profile**, each requirement naming the profiles and projects that need
it. Compiler-cache launchers are never listed as required here — whether a
missing launcher is actionable is decided by the compiler-cache provider alone,
so it is never reported twice. Language servers and debug adapters are never
required either, in either host: no headless operation uses them, and an editor
without them still builds.

Only a **missing required** result is **actionable**: it becomes a suggestion
whose `title` is "`<label>` not found — needed by `<profile/project>`" and whose
`remedy` is the result's `hint`, and it counts toward `N suggestions` (§16.18,
`spec/ui.md` §1.1). Every other result — found, missing but not required,
unknown — is informational and never counted.

**Cost and caching.** Probing is expensive, so it happens **only on an explicit
health run**, which always re-probes. Its results are stored in the health cache
(§16.31) as a third tier beside the local and network tiers:

- an **inventory tier** — the raw results (status, version, path; *not* the
  required split, which depends on the workspace), the declaration ids that
  were probed, the time they were computed, and an **environment key**: a
  digest of the normalized executable search path, the executable-extension
  list (Windows), the platform, the registered contributors (every discovered
  module, SDK provider and inventory companion, with its interface version or
  rejection), core's plugin-interface versions and an inventory key version
  (bumped when core's declaration ids or result recording change), plus the SDK
  installations the workspace's profiles pin (the one workspace-dependent
  declaration input). Computing the key spawns nothing and probes nothing: it
  reads in-process values and the contributor listing a workspace load already
  performs, plus at most one file-existence check.

  The key is **host-neutral**: the editor and the CLI on the same machine, with
  the same plugins, produce the same key, so the editor's count includes what an
  `lw health` recorded. Nothing identifying the running host takes part — not
  the location of the loomworks code nor its release version (an editor running
  from a plugin checkout has no release version; the contributor listing and
  interface versions stand in for it). The search path is normalized before
  digesting: entries split on the platform separator, unquoted, separators
  unified and case folded where the filesystem is case-insensitive, trailing
  separators and empty entries dropped, duplicates collapsed to their **first**
  occurrence — **order is kept**, since it decides which executable is found.
  Directories the editor injects into its own search path are removed: the
  editor-side package manager's executable directory under the editor's data
  directory (the same install location the language-server and debug-adapter
  declarations read, derived identically in both hosts), wherever it appears —
  its installs are listed from their own install tree instead — and, on Windows, a **last** entry holding the
  editor's executable (Neovim appends its own directory at startup; an entry
  the user placed earlier is kept, and an appended duplicate of it is already
  collapsed). A genuinely different search path — a directory added, removed or
  reordered — yields a different key.

The tier is added without a health-cache schema bump: a cache written before it
existed simply has no inventory tier (the inventory then counts nothing until
the next health run), and an older reader ignores it.

A passive collect (§16.31) **never probes**. When the cached inventory tier's
environment key matches, it derives the required split afresh from the current
workspace — a pure evaluation of `health_requirements` and the profiles, no
spawn — and adds the missing-required items to the count. When the key does not
match, or no inventory tier exists yet, the inventory contributes **nothing** to
the count: a result recorded for another environment is not trusted and is not
recomputed. So installing a tool into a directory already on the search path is
picked up by the next health run, not by the passive count — the same rule the
compiler-cache provider follows (§16.31). There is **no time-to-live**: the
nag names its own re-check (`lw health`), and a TTL would make the count change
with nothing having changed. The cache is **per workspace** (the search path and
the SDK declarations can differ per workspace shell); outside a workspace nothing
is cached (as for the local tier, §16.31) and every health run probes live.

**Budget.** A health run's inventory costs its slowest probe, not the sum
(probes run concurrently): the target is a couple of seconds on a typical
machine, with the per-probe timeout (a few seconds) as the ceiling. The passive
path's added cost is one digest of in-process strings plus the pure requirement
evaluation.

**Rendering.** Terse, one line per result: a status mark — `✓` found, `✗`
missing and required, `–` missing and not required, `?` unknown — the label,
version, and location — or, for a missing result, its `hint`. Inside a workspace the
actionable suggestions come first (§16.31), then **Required by this workspace**
(one line per item, naming what needs it), then **Other**, compacted to one line
per category (found items with versions, missing ones marked), then one `lw`
line. Outside a workspace there is no split: after the init hint (§16.31) every
category is listed one line per item. A verbose flag expands **Other** to one
line per item with locations.

**Machine-readable output.** A JSON flag prints one document instead of the
report: `{ schema, workspace?, suggestions[], inventory[] }` — `workspace` is
`{ name, root }` when there is one, each suggestion is `{ kind, title, detail?,
remedy? }` (the full health list, actionable and informational), and each
inventory entry is a result plus `category`, `required` (boolean) and
`required_by` (profile/project names); `hint` is carried only by an entry that is
not found (a found item's install remedy is noise). Object keys are emitted in
sorted order at every depth and arrays in their defined order (inventory: category
order, then declaration order), so the same data prints byte-identically — stable
for scripts and CI diffs. It carries the same data as the text report, is
versioned by `schema`, and exits 0 like the report — health never fails. There
is no check mode that exits non-zero on a missing required item in this version
(suggestions are advisory, §16.31); CI can test `required && status ==
"missing"` in the JSON.

**Editor.** The editor status page's count reads the same cache, so it reflects
missing required items once a health run has recorded them. An editor-native
health rendering of the inventory is deferred (the probes are host-neutral, so
it can later render the same results).

**Out of scope for this version:** minimum-version requirements (a found tool
that is too old reads as found); installing or repairing anything; editor-only
registry lookups; a per-user cross-workspace cache; a non-zero check mode; an
editor-native health rendering; probing on any path other than an explicit
health run.
