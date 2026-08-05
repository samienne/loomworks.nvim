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
