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
by the caller. Absent an explicit selection, the invocation is an error
unless exactly one published profile exists — the system never guesses a
default.

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

### 16.4 Cache-cold vs cache-warm

Build-unit readiness derives from the cache (§3.1). For a build unit with
no valid cache entry, a headless invocation MUST perform the full readiness
sequence — tool detection (§3.3) then configure (§5.2) — before build. For
a unit with a valid cache entry it MAY build directly. Tool identity
resolves from live detection when available, otherwise from cached tool
data (§1.5, §2.3); resolution MUST succeed from cache alone when detection
has not run.

### 16.5 Toolchain provisioning boundary

A headless host detects toolchains present on the system; it does not
install them. Provisioning build tools is outside the system's contract,
except SDK-provided toolchains (§10).

### 16.6 Non-invasiveness

A headless build is read-only toward project sources and toward the working
copy. Only the cache and build directories are written, under the safety
rules of §2.3 and §5.3. This contract does not itself serialize cross-process
concurrent access to a shared build directory; a host MAY add advisory
exclusion. loomworks does: configure/build/clean hold a **per-build-directory
advisory lockfile** — an `O_EXCL` create (atomic across processes) with an
mtime heartbeat so a crashed holder's lock goes stale and is reclaimed. The
editor and the CLI share this lock, so neither builds a directory the other is
building; acquisition is **fail-fast** (the loser reports the holder and
declines rather than waiting). A stale lock is reclaimed automatically after
the heartbeat window; `lw unlock` clears one immediately.

### 16.7 Reporting

Success or failure is reported via process exit status; task output streams
to standard output and standard error. No editor UI is required or
produced.

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
a read-only or CI invocation neither fetches nor mutates the active bundle.

### 16.14 Host/bundle compatibility

A release bundle declares the minimum runtime-host capability it requires. A
host that does not meet a bundle's minimum MUST refuse to execute it — rather
than fail unpredictably — and MUST report that a host update is required.
Within its compatible range a single host build executes any bundle, so
behavioral updates ship as bundles without replacing the host.

### 16.15 Host acquisition integrity

The host cannot verify itself — the component that checks a signature (§16.12)
is inside the host. A host binary's integrity is therefore established
out-of-band: it is obtained and checked against a hash published through a
trusted channel *before* its first execution, and only a matching binary is
run. Installation is that binary placing itself where it can be invoked; it is
not part of the verified-bundle chain and MUST NOT be assumed to have verified
the running binary. Once trusted this way, the host bootstraps the bundle chain
(§16.12–16.13).

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

**Argument forwarding.** Positional arguments after a `--` separator are
forwarded verbatim to the launched program (a command configuration's own
declared arguments precede them). The separator is required to pass arguments,
so the optional target-name positional is never ambiguous with program
arguments.

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
build state, and the resolved toolchain.

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
