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
gate's reason — `first configure`, `configure record missing (existing build
directory)` (§5.1), `previous configure failed`, `forced
(--reconfigure)`, a staleness reason (§5.1: `configure record from an older
lw`, `options changed (<names> added|changed|removed)`, `module configuration
changed`, `configuration environment changed`, `compiler launcher changed`),
`project files changed`, or `build directory missing` — prefixed with the
module's classification (§8.1 `reconfigure`): `configure: <reason>` for a
first configure (or when the module does not say), `full reconfigure
(<mechanism>): <reason>`, or `reconfigure (in place): <reason>`. For example
`full reconfigure (--fresh): configure record from an older lw`. The editor
logs the same line.

**The command line.** Every configure and build step — headless or from the
editor — writes its full command line and working directory to the workspace
log at info level; asked to (`lw build -v` / `--verbose`), the runner also
prints them under the step's header. A step whose command is a wrapper shows
the command the wrapper runs (§8.1 `display_cmd`), not the wrapper. Arguments
are quoted for readability, and data in them is rendered like any other
(§16.7). The workspace log (`.nvim/loomworks.log`) is appended to by every host
and never truncated; past 1 MB it is rotated to `loomworks.log.1`, keeping one
old file.

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

**Build arguments and targets.** A build MAY carry a **build request**: a
list of **targets** to build instead of the default set (`lw build <profile>
--target <name>`, repeatable) and a list of raw **build-tool arguments**
(`lw build <profile> -- <args>`). Both apply to the build steps only — never
to a configure — and reach the module as its build request (§8.1), which puts
them on the native build command before any wrapping, so they take effect
exactly as if typed on that command (e.g. cmake `--build <dir> --target <t>
<args>`, meson `compile -C <dir> <t> <args>`), whatever toolchain environment
the build runs in. An argument the build's wrapper cannot pass through
faithfully is refused with the reason, never dropped. Targets are applied to
every project of the profile; a project whose module does not support target
selection makes a `--target` build an error, as does forwarding arguments to a
module that neither accepts them nor runs a command they could be appended to
(§8.1). Targets are not refused up front against the unit's introspected
target list (it can omit targets the module does not introspect); the build
tool decides, and when such a build fails the closing message names each
requested target the list lacks, with close matches.

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
its build locks on interrupt as well as on normal exit, so an interrupted
(Ctrl-C'd) build does not leave a lock for the stale-reclaim window. An
**interrupt** is any of: SIGINT (Ctrl-C), SIGTERM, SIGHUP (a terminal hangup)
and, on Windows, CTRL_BREAK_EVENT and CTRL_CLOSE_EVENT (the console window
closed) — each takes the same cleanup path and exits 130.

The state files themselves are shared under the concurrent-writer rules of
§2.7, which every host follows: a headless build that records its result in the
build cache merges with whatever the editor (or another CLI) wrote there
meanwhile instead of overwriting it, and the editor merges the CLI's build
records the same way when it saves inside its reconciliation window. A
headless working-copy mutation (`lw project …`, `lw profile …`, …) whose save
finds the working copy changed on disk since the command read it writes
nothing and exits **1** with `lw: the working copy … changed on disk …` — the
command is re-run, not merged. A working copy or build cache whose schema is
newer than the running version (§2.7) refuses the command with the update
message and is left unchanged.

### 16.7 Reporting

Success or failure is reported via process exit status; task output streams
to standard output and standard error. No editor UI is required or
produced.

Text the runner prints on its own behalf — status, health, profile,
configuration and tool listings, diagnostics — routinely includes **data**
read from the workspace files, the cache, the health cache or tool probes
(names, paths, versions, option values), which a cloned repository controls.
Such data MUST NOT reach the terminal as control sequences: every control
character except tab and line feed is rendered visibly (e.g. escape as `^[`),
so data can never move the cursor, rewrite the screen, set the window title or
clipboard, or forge hyperlinks. The runner's own coloring (on a terminal only)
is unaffected. Output relayed verbatim from a build tool or launched program is
that program's own output and is passed through unchanged.

Every command documents itself: `lw help <command>` and, equivalently,
`--help` / `-h` anywhere among a command's own arguments (never after the `--`
that hands the rest to a build tool or program) print that command's help and
exit 0 — the flag is never read as an operand such as a profile name. This
holds for the host-level commands too (version reporting, self-update,
installation, pin management): asking for their help never performs them.
Help does not depend on the bundle: a host with no system Lua to run (a
release host before its first acquisition, §16.13) still answers every help
request with exit 0 — the host-level commands' own help for those commands,
and otherwise a short usage listing the host-level commands — stating that
full help needs the bundle and naming the acquisition operation.
The help a host gives for its **own** commands is their complete help, identical
to what the bundle's help prints for them (one source of the text, owned by the
host), so it carries no "full help needs the bundle" note; that note appears
only for a command the host cannot document. Inside a repository that carries a
version pin (§16.21) the note names the **repo launcher** as the way to reach
full help (it runs the pinned release, whose bundle it provisions), not the
machine-global acquisition — a user of a pinned repository has no reason to
install a global bundle. Answering help never fetches anything.

**Unknown options.** An option (a token starting with `-`, other than a lone
`-`) that the command does not know is a **usage error** (exit 2): it names the
option and points at `lw help <command>`, and nothing runs — a mistyped option
never falls through to a build or a launch. The global options (non-interactive
control, create intent, source selection, pin bypass) are known to every
command. The check stops at `--`: what follows belongs to a program or native
tool and is passed through untouched. It also stops where a command's grammar
hands the rest of the line to someone else or takes a value that may itself
start with `-`: the program arguments after a launch configuration's command
(or target), and a set-value operand (a configuration parameter's value, a
project variable's default, a profile fill). Commands whose grammar turns every
unrecognised token into a program argument (editing a launch configuration's
arguments) and the host-level commands (version reporting, self-update,
installation, pin management) keep their own parsing.

**Unknown commands.** A command name the runner does not know is likewise a
**usage error** (exit 2) that names it and points at the command index
(`lw help`). An option in the command position — a first token starting with
`-` that is neither a global option nor one of the help / version spellings — is
reported as an **unknown option** in the same form, never as an unknown command.
Both are decided from the command name alone, **before** workspace resolution:
outside a workspace a mistyped command reports the typo, never a missing
workspace, and nothing is read or written. A help request on an unknown command
(`lw <unknown> --help`) still prints the general usage and exits 0, as above.

**Host-level output is ASCII.** Everything printed before system Lua is loaded
— the repo launchers (§16.22), the host-level commands (version reporting,
self-update, installation, pin management), redirect and provisioning notices
(§16.23), the "what's new" lines self-update prints from the release notes
(§16.32, §16.37) — uses ASCII only (e.g. `-`, `->`, `...`, `|`), because it runs before
the runner can set the console's output encoding and it is the output most
often captured into CI logs and consoles with a legacy code page. Data it
relays (paths, versions) is printed as-is. Output produced by system Lua, which
sets a UTF-8 console output encoding on Windows before printing, is not bound
by this rule.
A sub-command's help (`lw help <command> <sub-command>`, or `--help` after the
sub-command) prints only that sub-command's part of the command's help, with a
pointer to the whole; a sub-command the help does not document falls back to
the whole command's help. User-facing help is self-contained: it never cites
specification sections.

This applies to the host's own commands as well: pin management's help
(`lw help bootstrap`) is organised by sub-command — the status page, `install`,
`upgrade` — so `lw help bootstrap install` and `lw bootstrap install --help`
print only the `install` part with a pointer to the whole, from the host's own
help text, with or without a bundle. The removed `update` (§16.24) has no help
topic. Asking for help of a writing sub-command never performs it.

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
when it would reach the published snapshot. "Reaching the published snapshot"
requires a `loomworks.json` to exist: in a local-only workspace (no
`loomworks.json` yet) no edit prints the `lw publish` reminder, for every
management edit (set, describe, rename, map). `get` returns the resolved string for the full path, or the
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
preset variant has no user-owned name to change. A rename carries every field
the configuration declares, including its description (§1.10), never a fixed
subset.

A management host MAY also **rename a launch configuration** in place, addressed
by `(project, old, new)`. The operation is the atomic rename of §8.7: the whole
launch table moves, including `deploy`, `device`, `device_log`, `debug`,
`description` and unknown fields, and every profile's default-target
descriptor that names it follows. The same refusals apply: an invalid or
colliding new name, or an unknown old name. When the new name is also the name
of one of the project's build targets, the rename succeeds with a warning on
stderr (`lw run <name>` then needs `--launch` / `--target`, §16.17). The
targets are those of the project's configured builds, scanned on demand as
`lw target` does. When none is configured yet, the check cannot be made and a
note on stderr says so.

A management host MAY also **set, replace or clear the description** (§1.10) of
a project, a user configuration, a configuration set, a profile or a launch
configuration (§16.35).

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
under `--no-input` a build refuses while any blank remains, naming the
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

The runner declares an installation either from a supplied path or, with none,
from the provider's detected installations (§10.1) — never prompting when it
cannot prompt: several candidates are then an error that lists each as the
explicit with-path declaration. It also lists every provider's detected
installations on request, read-only and outside a workspace.

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

The trusted key carried by the host is the **production release public key in
every build**, including a host built from a working tree: the committed
source embeds it (a public key is not secret), so a development build verifies
official releases exactly as a release build does and can author or update a
pin (§16.24) or self-update against them. A test suite that verifies
test-signed artifacts supplies its test key **explicitly** (a parameter, or a
host fused for the test with that key); no environment value, setting or
repository content can change the key a host trusts. The release build
asserts that the key it embeds is the committed production key, so the
source and the released hosts cannot drift. A signature that does not verify
is reported as such, naming the key the host trusts (a short fingerprint) and
whether that is the production key, and suggesting the likely causes (a
corrupt or non-official artifact; a mirror serving other files) — never only
"does not verify".

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

Besides system Lua, a bundle carries its release's **release notes** (§16.37)
as a data file inside the signed archive; the manifest's hash over the archive
covers them, so they need no signature of their own. A bundle's features that
rely on the host — rather than on system Lua alone — degrade on an older host
within the compatible range instead of failing; release notes rely on none.

### 16.15 Host acquisition integrity

The host cannot verify itself — the component that checks a signature (§16.12)
is inside the host. A host binary's integrity is therefore established
out-of-band: it is obtained and checked against a hash published through a
trusted channel *before* its first execution, and only a matching binary is
run. Installation is that binary placing itself where it can be invoked; it is
not part of the verified-bundle chain and MUST NOT be assumed to have verified
the running binary. Once trusted this way, the host bootstraps the bundle chain
(§16.12–16.13).

Installation never silently replaces a **different** host already at the
install location. When the location holds a binary whose content differs from
the running one, installation first describes it — as far as that is knowable
without executing it: whether it is a development build or which release it
is, its size, and its modification time — and asks for confirmation. An
explicit assume-yes flag skips the question; a non-interactive invocation
without it refuses, with a non-zero status, and leaves the existing binary
untouched. A binary identical to the running one is reported as already
installed. A dry run reports the replacement without asking or changing
anything. A later replacement of an installed host (§16.32) is verified
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

A headless test invocation MAY instead name one or more **test
executables** (build targets). Each named target is built, then run directly —
not through the native batch runner — with its framework's machine-readable
results option (§8.9), and its outcome is judged per §18.6 (exit status, parsed
failures, missing results, crash reports). A named target that is **foreign**
(§18.1) runs on a device (§18.5–§18.6; device selection §18.3) and its results
file is pulled back; a host-runnable one runs locally. Caller-forwarded
arguments go to each named executable. A JUnit request writes the parsed
results (one file per executable when several run). Naming targets never runs
the batch runner, and a batch-runner invocation never executes a foreign
artifact on the host (§15 invariant 19): a profile whose kit is foreign and
names no targets reports that its registered tests cannot run on this host
(until the module can express them for a device, §18.6) instead of running them.

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
editor's non-debug launch, excludes debugger attachment and module device
targets (§11; both deferred). A build target whose artifact is
**foreign** (§18.1) is run on a device instead of the host: the chain becomes
build → deploy → stage → execute (§18.4–§18.5), the device is resolved per
§18.3 (a device option selects it for this invocation), forwarded arguments
reach the device program verbatim, output streams to the invoking terminal, and
the device program's exit status is the invocation's exit status (a lost status
is a transport failure with its own non-zero status and message). Standard
input is not forwarded. When no device runner serves the artifact's platform
the run is refused (§18.1) — never executed locally.

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

**Launch prefix.** A run MAY interpose a **prefix command** before the resolved launch command: the launched process becomes `<prefix tokens> <resolved command> <arguments>`, executed in the launch's resolved working directory and environment (§8.6) with the same terminal attachment as an unprefixed run (above). The prefix is a host-level wrapper the system does **not** interpret, so it serves any external launcher — a memory checker, tracer, profiler, timing tool, or an interactive debugger invoked on the program (e.g. `valgrind`, `gdb --args`). It is therefore distinct from debugger *attachment* orchestrated by the system (deferred, above): the system execs the wrapper unaware of its purpose. Running the wrapper **inside** the resolved working directory and environment is the point — a caller cannot reproduce it by wrapping the run invocation itself, which would wrap the resolver, not the program. A prefix is **multiple tokens** (e.g. `valgrind --leak-check=full`); it is supplied as an option, so it consumes neither the positional operands nor the forwarded arguments, and a host defines how the tokens are given (a tokenized string and/or a repeatable option). The launched process's exit status remains the invocation's exit status. A prefix on a **device target** or a **foreign** build target is an error — a local wrapper does not apply to on-device execution.

**Command inspection.** A run MAY resolve the launch **without executing it**, reporting the fully-resolved invocation instead: the command and its arguments (a command configuration's declared arguments and any forwarded arguments included), the working directory, and the environment overrides the launch contributes — not the inherited environment. This is a read-only report (§16.9), for inspection or for a caller that drives execution itself. A build target's command is known only once its artifact is (§16.18); an unresolved artifact is reported as unresolved, never guessed (§16.3). **Output streams.** The dependency build's output (and the runner's own status lines) goes to standard output, as for a plain build (§16.7) — except when standard output carries a machine-readable payload (the inspection report below, in either format), where it goes to standard error so the payload stays parseable. The launched program's output is its own and is never redirected. Because the working directory and environment are reported rather than applied, a caller that reconstructs the invocation is responsible for reproducing them — the prefix mechanism (above) is the faithful way to run under a wrapper. Whether the dependency build (§16.4) precedes the report or is skipped is a host option. A host MAY also offer a **dry run**: the same report, but the run never builds, deploys or executes anything — it implies skipping the dependency build. A build target whose artifact path is known but whose program does not exist yet (never built) is still reported, with a note on the diagnostic stream that it is not built; this is not a failure. A foreign target's report needs the built files for its staging manifest, so an unbuilt one is reported as unbuilt (§16.3). For a foreign target the report names the device-side invocation instead — device, staged program path, arguments, working directory, library directories and device environment — plus the staging manifest; nothing is staged or executed.

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
on its own line, followed by a pointer to the command index (`lw help`); the
health report's lead (§16.31), which reuses the start-one hint, does not repeat
that pointer. When a workspace does resolve, the overview MAY present the
active profile's launchable targets, marking its default target and — when the
list is incomplete because a project is not yet configured — pointing the user
at how to configure it. When the invocation sits in a linked git worktree whose main
checkout holds a workspace, the hint offers to **pull** that config into the
current worktree (§16.25) as well as to initialise a fresh workspace here; when
the main checkout has no workspace — or the invocation is not in a linked
worktree — it offers only to initialise one. Detecting the parent worktree is a
best-effort, time-bounded hint: it never fails the report, and a slow or absent
git only adds a small bounded delay.

A workspace can resolve in a linked worktree from the committed published
snapshot alone, with no working copy and therefore no profiles (§16.25). When
the overview finds **no profiles** and the invocation sits in a linked git
worktree whose main checkout holds a **working copy**, the no-profiles hint
offers to **pull** (§16.25) before offering to create a profile. The test is the
working copy's presence only — the overview never reads, parses or verifies the
main checkout's files (pull does, §16.25, and reports "nothing to pull" when
there is nothing). The detection is the same best-effort, time-bounded one as
above and runs only in the no-profiles case, so a workspace with profiles pays
no git cost.

The overview ends with a **command footer**: one line naming the common
everyday commands (building, running, testing, cleaning, resetting, health,
pulling, creating a worktree, publishing), then the pointer to the full command
index and to per-command help. The footer is fixed text — it does not vary with
the workspace's state — and fits an 80-column terminal. It is what makes the
everyday commands discoverable without first reading help (§16.38).

When the workspace resolved only by continuing the upward root search past a
git submodule (§1.1) — the invocation sits inside a submodule of the
superproject that holds the workspace — the overview says so in one dim line
under its title, naming the superproject root and the submodule the
invocation came from, so an operation that acts on the superproject's build
is not a surprise. Every other operation resolves the same root silently.

The overview MAY also surface the workspace's **diagnostics** — the same set
the interactive host presents — as a top section shown only when non-empty,
with each per-item warning or error also shown inline under the profile,
configuration set, or project it concerns. A `--check` flag makes the
invocation report a non-zero exit status when any diagnostic is present (for
CI); without it the overview always exits successfully, since it neither builds
nor manages state (§16.9). `--check` never changes what is rendered — only the
exit status. When **no workspace** resolves, `--check` reports a non-zero exit
status too (a gate run outside a workspace is a misconfigured job), rendering
the same no-workspace page.

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
A launcher caches the host binary it downloads under a cache directory inside
the repository that is ignored by version control, so nothing fetched is ever
committed. Everything the **host** provisions or caches for a pinned run — the
pinned bundle (§16.22) and the host binary a redirect runs (§16.23) — lives in
the **per-user data directory**, never inside the repository (§16.22).

A repository MAY instead commit **the pin alone** (**pin-only**, §16.24). The pin
then takes effect only through a globally-installed host, whose redirect
(§16.23) runs the pinned release for workspace operations; contributors and CI
need a global install, but nothing executable is committed. The pin's content,
verification and escapes are the same in both forms.

The launchers are committed with fixed line endings and the POSIX launcher
with its executable bit: the POSIX launcher and the pin use LF, the Windows
launcher uses CRLF, recorded as the repository's own line-ending attributes so
every checkout on every platform gets them regardless of the user's line-ending
configuration (§16.24). Which launcher to use depends on the shell, not the
operating system: a POSIX shell — including the Unix-style shells on Windows
(Git Bash, MSYS2, Cygwin) — runs the POSIX launcher by relative path
(`./lw.sh`), which selects the Windows host binary there; the native Windows
command interpreters run the Windows launcher by explicit relative path
(`.\lw.cmd`), since a bare launcher name can resolve to a same-named file
elsewhere on the search path. Help and authoring output always show the
relative form.

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

**Download behavior (both launchers, identically).** A download is **quiet
and bounded**:

- before fetching, the launcher prints exactly one line naming the pinned
  version, the asset, and the pin it read (e.g. `lw: fetching pinned lw 0.1.35
  (lw-linux-x86_64) for /home/me/repo/lw.pin...`), so a user can tell which pin and which
  launcher ran; the downloader's own progress display is suppressed (it renders
  as noise in CI logs and some consoles), while its error messages are kept.
  A run that finds the binary already cached and verified prints nothing of its
  own — the launcher adds no output to an ordinary run;
- a failed transfer is **retried**: at most three attempts, with an increasing
  delay between them (on the order of 1 s, then 2 s), each attempt starting
  from an empty file; a definitive client error (an HTTP 4xx other than 408 and
  429) MAY end the attempts early, matching the rule the host applies to its
  own acquisition downloads. The hash check applies to the final
  file exactly as before — a retry never relaxes it. A local-path mirror is a
  copy and is not retried;
- after all attempts fail, one line names the URL and that the attempts were
  exhausted, and the launcher exits non-zero with nothing left in the cache.

The host's own downloads (acquisition, self-update, pin provisioning and the
redirect, pin management) already retry transient failures with backoff and
are unchanged; the health update check keeps its bounded, no-retry probe
(§16.31).

**Interrupts.** An interrupt (§16.6) while the host runs is the host's to
handle: it reaches the host, which cleans up and exits 130, and the launcher
then exits with the host's status — it adds no prompt, no output and no wait of
its own. In particular the Windows launcher MUST NOT leave the command
interpreter asking whether to terminate the batch job after a Ctrl-C or
Ctrl-Break (it clears the interpreter's pending interrupt once the host has
exited), so the console returns at once and a calling script sees status 130.

The launcher's cache directory holds only artifacts it can re-fetch: the
cached host binaries (one per pinned version and asset) and a marker naming
the last one fetched. Older cached binaries are pruned by pin management
(§16.24), never by the launcher itself.

Because a host binary carries only the runtime bootstrap and not the behavioral
system Lua (§16.11), a host running in **pinned context** — launched by the repo
launcher, or re-exec'd by the redirect (§16.23) — MUST **provision** the pinned
release's bundle before it resolves system Lua (a command that resolves none —
pin management, §16.24 — provisions nothing): acquire the bundle for the pinned
version, verify it against the pinned bundle hash, and extract it to a
**pinned-release cache in the per-user data directory**, keyed by the pinned
version **and** the pinned bundle hash, then resolve system Lua from there rather
than from the newest machine-global install. Provisioning is idempotent: a bundle
the host itself extracted there after verification is reused without
re-downloading, and a failed or partial provision leaves any prior state intact
(§16.13). Pinning keeps a run reproducible — host and bundle are the same pinned
version — and leaves the machine-global installation (§16.13) untouched. The
trust anchor for provisioning is the **committed pin hash** checked against an
artifact the host fetched from the fixed origin (§16.23), consistent with
§16.15/§16.20 anchoring integrity to something other than the served artifact.

A pinned host MUST NOT execute or load anything it did not fetch and verify
itself: in particular it never trusts a bundle or binary found **inside the
repository** (such as an "already extracted" bundle under the repository's cache
directory) because it exists — a cloned repository can ship arbitrary files
there. That is why the provisioned artifacts live outside the repository. The
repository-local location used by earlier hosts is never read; when a redirect
(§16.23) targets a pinned release whose host still reads that location, the
redirecting host first verifies that the location is absent or byte-for-byte
identical to the bundle it verified, and otherwise refuses the redirect (it
never deletes repository content).

**Self-identification.** A launcher tells the host it runs which launcher it
is, in an environment value set only for that process (`LOOMWORKS_LAUNCHER`,
`lw.sh` or `lw.cmd`, beside the pinned-context sentinel; also on the
development override path), so the host spells the commands it prints in that
launcher's form (§16.24 "Invoked form"). The host removes the value from its own
environment once read, so nothing it starts inherits it. A launcher that does not
set it (an earlier generation) is still honoured, with the `./lw.sh` form.

A launcher never downloads or extracts the bundle itself — it fetches and execs
only the host binary, and the exec'd host self-provisions the bundle as above,
so the launcher depends on nothing beyond a system downloader and a hash tool.
The native Windows launcher invokes the operating system's own tools by their
absolute system location, never by a bare name resolved through the search path,
so a same-named tool from another toolset placed earlier on the path (as in a
Unix-style shell environment) cannot change its behavior.

### 16.23 Global pin-aware redirect

A globally-installed host, invoked for a **workspace operation** (build, run,
test, configure, clean) inside a repository that carries a pin, MUST honor the
pin. It resolves the pinned version from the workspace root — the same root
discovery that locates the workspace files (§2). When the pinned version equals
the running host's own release version it runs the operation **in-process**: no
download and no redirect (the fast path). When they differ it MUST acquire and
verify the pinned host binary, provision the pinned bundle (§16.22), and
**re-exec** the pinned binary with the same arguments, so the operation runs
under exactly the pinned release. Where the re-exec is a child process rather
than a replacement of the process, it MUST behave as a replacement would: the
redirecting host shares its standard streams with the pinned host, waits for it
and exits with its status (128 + the signal number when a signal ended it). It
never acts on an interrupt (§16.6) itself — the pinned host handles it and
cleans up, and the redirecting host neither dies nor exits before the pinned
host has finished; an interrupt addressed to the redirecting host alone (a
POSIX signal sent to its process only) is forwarded to the pinned host.

Redirection applies only to workspace operations. **Host and management
operations** — reporting the host version, self-update, install, and pin
management (§16.24: the status page, `install` and `upgrade`) — MUST NOT
redirect; they always run as the invoked (global)
host, so that, for example, updating the pin is never carried out by the old
pinned version. Redirection MUST be guarded against recursion: once a host is
running as the pinned version with the pinned bundle loaded, it never redirects
or re-provisions again (a sentinel carried across the exec).

The redirect has explicit **escapes**, all caller-owned: a *no-pin* flag runs
the invoked host with no redirect; an environment override naming a host binary
runs that binary and bypasses the pin entirely (the development / test-at-head
path); and a development source (§16.11) likewise bypasses. The first redirect or
provision of an invocation emits a one-line notice rather than stalling silently.

The rule is the same when a launcher runs the host (pinned context, §16.22):
`./lw.sh bootstrap …` (and the removed `./lw.sh update`'s pointer) are management
operations of the pinned host itself — dispatched before any redirect decision
and, since they need no system Lua, before bundle provisioning (§16.24).

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
- **Nothing executed from the repository tree.** The host binary a redirect runs
  and the bundle it loads are the artifacts the host fetched and verified into
  the per-user pinned cache (§16.22) — never a same-named file shipped inside
  the repository, whatever its hash.
- **Bounded residual risk.** A malicious pin can at worst force acquisition of an
  authentic but **older / downgraded** official release; it cannot introduce
  unofficial code, because every fetched artifact must match a hash the host
  obtained from the fixed origin. Provenance anchored outside the project's
  infrastructure (§16.15) applied at redirect time is possible future hardening.

### 16.24 Pin management: status, install, upgrade

Pin management is one host command, **bootstrap**, with a read-only default and
one writing sub-command:

| Invocation | What it does |
|---|---|
| `lw bootstrap [--json] [--check]` | **Status page**: reports the pin, the launchers and the repository metadata, then what the user can do. Writes nothing. |
| `lw bootstrap install [--version <x.y.z> \| --latest [--channel <name>]] [--pin-only] [--force]` | **Converge**: brings the repository from any start state to a correct pin (and, unless `--pin-only`, launchers) plus metadata. First install, repair and version bump are all this one command. |
| `lw bootstrap upgrade [--channel <name>] [--pin-only] [--force]` | Alias of `lw bootstrap install --latest …`. |

All of them are **management operations** (§16.9): they never redirect
(§16.23) and run as whichever host is invoked. They need no system Lua — a
release host that has never acquired a bundle (§16.13) runs them — and they work
outside a loomworks workspace and outside a version-controlled tree; only the
version-control checks and steps below need a git work tree. An unknown
sub-command, a positional operand, or an install-only flag (`--version`,
`--latest`, `--channel`, `--pin-only`, `--force`) given to the status page is a
**usage error** (exit 2) that writes nothing and names the intended form (e.g.
"`lw bootstrap` only reports; to pin a release run `lw bootstrap install
--version 0.1.36`"). `--version` together with `--latest` is likewise a usage
error.

**Which directory.** Every form first looks for an existing pin by the upward
pin-root discovery of the redirect (§16.23), seeded from the launcher-passed
root or the current directory. When one is found, that **pin root** is the
directory reported and written. When none is found, the **target directory** is
the start directory itself (where `lw bootstrap` has always written). When the
target lies inside a git work tree but is not its top level, the status page
says so on its directory line ("not the repository root `<top>`"), and an
install that creates a pin there says so in its report, since a pin below the
top is only found from inside that subdirectory.

**Invoked form.** Every command lw prints for pin management — on the status
page, in a report, a remedy, a usage error or the removed-`update` pointer — is
spelled in the form that was invoked. A repo launcher **names itself** to the
host it runs (§16.22), so run through `lw.sh` the commands read `./lw.sh …` and
run through `lw.cmd` they read `.\lw.cmd …`; a pinned context whose launcher did
not name itself (a launcher written by an earlier release) prints the `./lw.sh`
form with `.\lw.cmd …` noted for cmd/PowerShell; otherwise the global form
(`lw bootstrap install`). The invoked host is the one whose launcher generation
a write produces (below), so a remedy is always a command that takes effect from
where the user stands.

**Checks: one source of truth.** The status page and the launcher provider of
`lw health` (§16.31 provider #4) evaluate **the same checks**, implemented once
and producing the same findings with the same wording and the same remedies;
they differ only in presentation (health prefixes each item `launcher:` and
lists it among its other suggestions; the status page groups them under its own
headings). The checks are those listed under provider #4 — pin parse and hash
coverage, launcher presence and generation, committed state, the POSIX
launcher's index mode, effective and committed line-ending attributes, committed
and checked-out line endings, the committed ignore rule, stale cached binaries —
scoped by the repository's **launcher mode** (below). **Committed** always means
the content of the last commit: a file that is untracked, staged but never
committed, or modified relative to it is not committed, and a rule counts only
when it is in the committed content of a tracked file of the repository.

**Launcher mode.** A pin root is in one of three modes, inferred from the files
(nothing records the mode):

- **launchers** — the pin with one or both launchers beside it: every check
  applies, and a missing launcher is actionable (a half-installed pair);
- **pin-only** — the pin with **neither** launcher: absent launchers are
  intended, not a finding. Only the checks that concern the pin apply — pin
  parse and hash coverage, the pin (and the attributes file) committed, the
  pin's `text eol=lf` attribute, its committed and checked-out line endings, and
  stale cached binaries (left over from launchers that were removed). The exec bit, the Windows launcher's
  rule and the launcher-cache ignore rule are not checked (nothing uses them);
- **none** — no pin found.

#### Status page (`lw bootstrap`)

A read-only report, ASCII (§16.7), in three parts.

1. **State.** One labelled line each: the directory (the pin root, or the target
   directory with "no lw.pin"); the pin (`lw.pin -> lw <version>` and its hash
   coverage, or "none", or why it cannot be read); the **release** line — the
   newest release on the resolved update channel (§16.29) compared with the
   pinned version (or, with no pin, the version an install would pin): "`<newest>`
   is available on the `<channel>` channel" when it is newer; "`<pinned>` is the
   newest on the `<channel>` channel" when they are equal; and, when the pin is
   **ahead** of the channel (typically a prerelease pinned while following
   stable), "pinned prerelease `<pinned>`; newest stable: `<newest>`" (or "pinned
   `<pinned>`; newest `<channel>`: `<newest>`" for a non-prerelease), followed by
   the newest unstable release when it is newer than the pin ("; newest
   unstable: `<u>`", with the command to take it) — never a claim that the pin is
   the channel's newest; the launcher mode and
   each launcher's generation state (current / written by lw `<releases>` / not
   a launcher lw wrote / missing); and — inside a git work tree with git
   available — the index mode, the committed and checked-out line endings, the
   effective attributes and the ignore rule, each only as far as the mode
   applies (the committed state names the files not committed yet). The release
   line is the only network operation (two probes when the pin is ahead: the
   channel's newest and the newest unstable): it uses the health
   update check's bounded, no-retry probe (§16.31 provider #2: 5 s connect,
   10 s total, never a bundle download) and on failure reads "not checked -
   offline or release server unreachable"; nothing is cached. A
   development-build host performs it too (to offer `--latest`).
2. **Findings.** The checks' items, actionable first (`*`), then informational
   (`-`), as in the health report (§16.31), each with its detail and, for an
   actionable one, its exact fix command. When there are none, one line affirms
   the healthy state (the same affirmation health prints).
3. **What you can do.** A short list of commands, each with a one-line reason,
   tailored to the state; the first line is the most useful action:
   - **no pin** → `lw bootstrap install` "pin this repo to lw `<host version>`
     and add lw.sh / lw.cmd" (a development-build host instead leads with
     `lw bootstrap install --latest` naming the newest release); then
     `--pin-only` "pin without launcher scripts (contributors and CI then need a
     global lw)"; `--version <x.y.z>` "pin a different release"; `lw help
     bootstrap`;
   - **pin-only** → `lw bootstrap install` "add lw.sh / lw.cmd so contributors
     and CI need no global lw"; a pin-scoped finding's fix is `lw bootstrap
     install --pin-only` (plain `install` would also add the launchers);
   - **a finding** → its exact fix command first (usually `lw bootstrap
     install`, which keeps the pin; `install --force` to restore a launcher that
     is not one lw wrote; the renormalize command for committed line endings);
   - **files not committed** → one `git add <files> && git commit` naming every
     file a finding says is not committed (lw never commits);
   - **a newer release** → `lw bootstrap upgrade` "move the pin to `<newest>`",
     plus, when the invoked host is older than `<newest>` and launchers are in
     use, "then run `… bootstrap install` once more to take `<newest>`'s
     launchers" (see *Upgrading through the launcher*);
   - **healthy and current** → `lw bootstrap install --version <x.y.z>` "pin a
     different release" and `lw help bootstrap`.

   For **one release after this change** the block ends with the migration note
   "`lw bootstrap` only reports now; `lw bootstrap install` writes the files"
   whenever the mode is **none** (the user most likely expected the old writing
   behaviour).

**Exit status.** The status page exits **0** whatever it finds (like `lw status`
and `lw health`, §16.18/§16.31). With **`--check`** it exits **1** when there is
no pin or there is any **actionable** finding, else 0 — for a CI step that
guards the committed launcher files. What counts: a pin that cannot be read or
lacks a hash; a missing launcher (outside pin-only), a launcher generation with
a breaking defect, or a launcher that is **not one lw wrote** (local edits:
restore it with `install --force`, or keep the edits and do not guard with
`--check`); pin, launcher or metadata files **not committed** (untracked,
staged only, or modified); line-ending rules missing or not committed; wrong
committed or checked-out line endings; the POSIX launcher not executable in the
index; the launcher cache not ignored by a committed rule. What never counts:
informational findings (an older launcher generation with only cosmetic
differences, stale cached binaries), an available newer release, a pin ahead of
the channel, and a failed release check. `--check` never changes what is
printed. Usage errors exit 2.

**Machine-readable output.** `--json` prints one document instead of the page,
following the health document's conventions (§16.33: sorted object keys at every
depth, arrays in their defined order, versioned by `schema`, the same exit rules
as the text form): `{ schema, root, repo_top?, mode, invoked, launcher?, pin?,
launchers, update?, findings[], actions[], summary }` — `mode` is `launchers` |
`pin-only` | `none`; `invoked` is `launcher` | `global`, and `launcher` names it
(`lw.sh` | `lw.cmd`) when it named itself; `pin` is `{ version, file,
missing_hashes[] }` (absent with no pin; `{ file, error }` when unreadable);
`launchers` maps `lw.sh` and `lw.cmd` to `{ present, generation, releases? }`
with `generation` `current` | `known` | `unknown` | `absent`; `update` is the
health `update` shape `{ status, channel, current, newest?, detail? }` (`current`
being the pinned version, or the one an install would pin) with `status`
`available` | `current` | `ahead` (the pin is newer than the channel's newest) |
`unknown`, plus `newest_unstable` when the pin is ahead and the unstable channel
was probed; each finding is the
health suggestion shape `{ kind, title, detail?, remedy? }` without the
`launcher:` prefix; each action is `{ command, why }` in displayed order; and
`summary` is `{ actionable }`.

#### Install (`lw bootstrap install`)

One **idempotent converge** operation. From any start state — nothing, a pin
only, stale or hand-edited launchers, broken or missing metadata, a pin with a
missing hash — it brings the repository to the correct state, and a second run
changes nothing.

**Version selection:**

- **`--version <x.y.z>`** pins that release;
- **`--latest`** pins the newest release on the resolved update channel — the
  same resolution as the status page's release line (§16.29: `--channel` for
  this run > the environment > the `channel` setting > stable; a release-URL
  override supersedes the channel). It **never moves the pin backwards**: when
  the pin is already newer than the channel's newest (a pre-release pinned while
  following stable), the pin is kept and the report says so and names
  `--version` for an intentional downgrade. The report always starts by naming
  what it resolved ("newest unstable release: `<version>`"), so a run that
  changes nothing still says what the channel offers;
- **neither, with a pin** → the **pinned version** is kept. Plain `install` in a
  pinned repository therefore only repairs; it never bumps, whatever host runs
  it. `--version` / `--latest` are the only ways to move a pin;
- **neither, no pin** → the running host's release version; a development build
  has none and refuses, naming `--version <x.y.z>` and `--latest`.

The selected release's per-artifact hashes come from its **signed** hash list
(§16.15), whose signature is verified before any hash is trusted, so the pin's
committed hashes are anchored to the release key at authoring time; fetching it
also validates that the release is fetchable **before** anything is written, so
a bad version fails cleanly with the repository untouched. Runtime provisioning
(§16.22) then trusts the committed pin hash directly, since the pin has itself
reached the runner through the repository. The version a network lookup names
(`--latest`) only selects which signed hash list is fetched: it passes the
safe-version rule before use and is never trusted for integrity.

**Writes**, in order: the pin (rewritten whenever its content or line endings
differ from what the release gives — it is never "kept"); the two launchers
(below), unless `--pin-only`; the repository metadata (below); the prune of the
launcher cache (below).

**`--pin-only`.** Writes or refreshes only the pin and the metadata that
concerns it — the pin's `text eol=lf` attribute — and prunes the launcher cache.
It writes no launcher, adds no ignore rule, and stages nothing (the exec bit
concerns the POSIX launcher only). Launchers **already present** are left
exactly as they are — neither deleted nor refreshed — and the report says so in
one line ("kept lw.sh, lw.cmd as they are (--pin-only); `lw bootstrap install`
refreshes them"); pin management never deletes a launcher. Existing launchers
keep working across a pin bump, since they read the version and hashes from the
pin (a launcher generation with a known breaking defect is still reported by the
checks, which apply in full because the mode is then **launchers**). A later
plain `lw bootstrap install` adds or refreshes the launchers and their metadata,
keeping the pin.

**How a pin-only repository runs.** Without committed launchers, the pin takes
effect through a globally-installed host's redirect (§16.23): a global `lw`
running a workspace operation (build, run, test, configure, clean) in the
repository fetches, verifies and runs exactly the pinned release, or runs in
process when it already is that release. Users therefore need a global `lw`
(`lw help install`) — CI included, which must install one before its first `lw`
step; nothing else about the pin changes (the same hashes, the same
verification, the same `--no-pin` / override escapes). The pin does not govern
the **editor plugin**, which runs the plugin version installed in the editor;
editor delegation to a pinned release is not part of this contract. Pin-only
suits repositories whose contributors already have `lw` installed and that do not
want scripts in their root; launchers remain the choice for zero-install CI.

**Launcher generations and user edits.** The host knows the exact content of
every launcher it or an earlier release has written (a catalogue of launcher
**generations**, compared after normalizing line endings, each noting the
defects it is known to have). Before overwriting a launcher, install classifies
the file on disk: identical to what it would write → left alone and not reported
as refreshed; a known earlier generation → replaced; **not a known generation**
(edited by hand, or written by a newer host) → **not** overwritten: install
completes the rest of its work, reports the launcher as kept, and names
`--force`, which replaces it. A missing launcher (outside `--pin-only`) is
written.

**Repository metadata.** Install, on every run, makes sure the repository will
carry the files correctly, each step idempotent and append-only toward files the
user also edits. With `--pin-only` only the pin's attribute rule applies (above).

- **Ignore rule.** The launcher cache directory must be ignored **by the
  repository's own ignore rules**. When version control can answer which rule
  ignores a path, a rule in a committed ignore file of the repository that
  already covers the cache directory (for example one ignoring the whole
  workspace-state directory) satisfies this and nothing is appended; a match
  that comes only from the user's personal or repository-local, uncommitted
  exclude rules does **not** count, since teammates and CI do not have them, and
  neither does a matching line of the repository's own ignore file that is not
  in its committed content (untracked, staged only, or modified) — that one is
  reported as not committed, and nothing is appended either, since the rule is
  already there and committing it is what is missing. Otherwise — or when
  version control is unavailable and no line of the root ignore file names the
  cache directory or an ancestor of it — the cache directory is appended to the
  root ignore file, creating it if absent. Existing content is never rewritten
  or reordered.
- **Line-ending attributes.** The root attributes file must give the POSIX
  launcher and the pin `text eol=lf` and the Windows launcher `text eol=crlf`
  (§16.21). The check uses the **effective** attributes when version control can
  report them (so an equivalent rule already present, e.g. a pattern covering
  the files, suffices), else the presence of the exact lines. Only the missing
  rules are added: when the file already names some of the launcher files, the
  missing rule lines go right after the last of those lines, with no comment
  header of their own (the repository's own comment already introduces them);
  otherwise they are appended at the end under one header comment, creating the
  file if absent. Later lines of a file take precedence over earlier ones, so a
  rule added there wins over an earlier contrary line; existing content is never
  rewritten. A contrary rule the operation cannot override from there (a
  repository-local, uncommitted attributes file) is reported, not edited.
- **Line endings of the files it edits.** Every line added to the ignore or
  attributes file uses that file's existing line ending (CR LF when it already
  has CR LF lines, else LF), so an edit never leaves a file with mixed endings;
  a file being created uses what version control would check it out with (CR LF
  under an automatic CR LF conversion setting, else LF).
- **Executable bit.** Inside a version-controlled working tree, the POSIX
  launcher must be recorded as executable (mode `100755`). On a platform or
  checkout that does not track the bit through the file system (Windows), the
  bit exists only in the index, so: an untracked launcher is added to the index
  with the executable mode, and a tracked one recorded without it has its index
  mode set. This is the **only** staging install performs, and it is reported;
  the pin, the Windows launcher and the attribute/ignore files are left for the
  user to stage and commit. Outside version control, and on file systems that
  carry the bit, the file mode is set directly.

**Reporting.** Install reports what it changed and nothing else:

- a run that changes nothing reports `lw.pin already at <version> - no
  changes`; an unchanged pin in a run that changed something else reads
  `lw.pin kept at <version>` — the same words whichever host runs it;
- a moved pin reports `lw.pin: <old> -> <new>`, a first pin `wrote lw.pin:
  version <version>`; a pin moved to a **newer** release that carries release
  notes (§16.37) adds one line naming the command, in the invoked form, that
  shows what changed across the move (`what's new: ./lw.sh release-notes
  --since <old>`) — a pointer, not the notes: the host has not acquired the new
  bundle, and pin management never fetches more than it needs;
- the pin line always states that the release's signed hash list was verified,
  as one flat clause (`; hashes from the signed SHA256SUMS, signature
  verified`); report lines never nest parentheses;
- each launcher is reported as written when it was absent, as refreshed only
  when its content changed, naming the generation it replaced the same way
  everywhere (`replaced the launcher written by lw <releases>`, the release
  range being that file's own), and as kept (naming `--force`) when it was not a
  known generation; `--pin-only` with launchers present reports the one
  "kept … as they are" line above;
- each metadata step reports only an action it took (rule appended, executable
  bit staged) or a problem it could not fix;
- each pruned binary is named with its version, file name and size
  (`removed old pinned lw 0.1.36 (lw-0.1.36-lw-windows-x86_64.exe, 5.5 MB) from
  .nvim/cache`);
- a run that **created** the pin or a launcher closes with how to run the
  launchers (`./lw.sh <cmd>`, `.\lw.cmd <cmd>`) — or, for `--pin-only`, that a
  global `lw` honours the pin — and how to check it later (the status page);
- a run that wrote or changed files ends with the commit hint naming exactly
  those files (`Commit them: git add lw.pin .gitattributes && git commit`);
  install never commits.

**Exit status.** 0 when the repository reached the target state (a launcher kept
for lack of `--force` still counts: everything else converged and the report
says what to do); 1 when the release cannot be resolved, fetched or verified, or
a write fails; 2 for a usage error.

**Pruning the launcher cache.** After a successful run (including a run that
changed nothing, so a binary that was in use by the previous run is collected
later), install removes cached host binaries of **other** versions from the
launcher cache directory of that repository. Deletion is confined as follows:
the directory is exactly `<pin root>/<cache dir>`, resolved and checked to lie
under the pin root with a separator-bounded prefix comparison; only **regular
files directly in it** (never a directory, never a symbolic link or junction,
never recursion) whose name is exactly a cached-binary name — the cache's
prefix, a version that passes the safe-version rule (§16.23), and a known
host-binary asset name — are candidates; the binary for the pin's version is
never a candidate, nor is the running executable. A failure to remove one (e.g.
a binary still executing on Windows) is skipped silently and retried by the next
run; pruning never fails the operation. Legacy repository-local bundle
directories (§16.22) and the per-user pinned cache, which other repositories may
share, are not pruned.

**Upgrading through the launcher.** Pin management is a host command, so it runs
on whichever host is invoked. Run through the repository's launcher
(`./lw.sh bootstrap upgrade`) it runs as the **currently pinned** release — the
path that needs no global install, and the one that works when the global host
is a development build. That host moves the pin but can only write **its own**
launcher generation — a known limitation that is kept: a host cannot know the
templates of a release newer than itself. When the target release is newer than
the host running the operation and launchers are in use, the report says the
launchers were written by `<running version>` and that running `./lw.sh
bootstrap install` once more (now executing the new release, and keeping the
pin) refreshes them — a run that is otherwise a no-op. A global host (release or
development build, §16.12) can equally install or upgrade the pin directly,
writing its own generation.

**No bundle needed in pinned context.** Pin management and its status page need
no system Lua, so a host in pinned context running them does **not** provision
the pinned bundle first (§16.22): `./lw.sh bootstrap` reports its local checks
offline, and a pin whose bundle entry is wrong can still be repaired through the
launcher.

#### Removed `lw update`

`lw update` was the pin-bump command before `lw bootstrap`'s sub-commands; it
was kept from 0.1.37 through 0.1.42 as a deprecated alias of `lw bootstrap
install --latest` and is now **removed**. It is an unknown command, with one
difference from any other unknown command: the host answers it itself — before
pinned-bundle provisioning, without a bundle or a workspace, and also when it
carries `--help` / `-h` — with one line on standard error naming both commands
it is likely to have meant, then exits 2 (a usage error) having changed
nothing:

```
lw: unknown command 'update' - to move lw.pin to the newest release run `lw bootstrap upgrade`; to update lw itself run `lw self-update`
```

The `bootstrap upgrade` command is in the invoked form (`./lw.sh bootstrap
upgrade` through `lw.sh`); `lw self-update` is always the global form. The
nvim-hosted fallback CLI answers the same way. It is not offered by shell
completion and has no help topic. A host older than this change still runs its
own deprecated alias; nothing in the bundle is involved.

**Plain `lw bootstrap` changes meaning.** Before this change `lw bootstrap`
wrote the pin and launchers; now it is the read-only status page. A user who
expects the old behaviour sees the state (no pin) and a "What you can do" block
led by `lw bootstrap install`, plus the one-release migration note above; a
script passing the old flags (`lw bootstrap --version X`, `--force`) gets the
usage error (exit 2) naming `lw bootstrap install`, so it fails loudly instead
of silently writing nothing. Both changes are called out in the release notes
and in the README's launcher section.

### 16.25 Working-copy pull across checkouts

The working copy (§2.2) is machine-local and version-control-ignored, so a fresh
checkout — most commonly a linked git worktree — starts with no working copy and
therefore no profiles, configuration sets, or projects to build. A **management
operation** (§16.9) MAY **pull** another checkout's working config into the
current one, so a new checkout inherits a ready-to-build configuration without
re-authoring it.

Pull is a management write (§16.9): it authors the current working copy only,
never the published snapshot (§2.4) and never any build or cache state (§2.3).
It is never part of a build. It reads the source's working copy only when that
file carries a valid machine signature, and merges only into a target working
copy that is valid or absent; the result is signed (§17.5) — a pull never turns
an untrusted file into a signed one.

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

Under `--no-input` the refusal is **never a prompt**: the build simply
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
override, then host configuration, then the default (stable). Selecting a
channel **on self-update** (§16.32) also **saves** it into the host
configuration — the same setting the settings command writes — and says so, so
later self-updates and the version report follow it; re-selecting the saved
channel says it is already set, and an unknown channel is a usage error that
saves nothing. The environment override (`LOOMWORKS_CHANNEL`) still overrides
the saved channel for any run where it is set; when it differs from the channel
just saved, self-update notes that. Other operations that take a channel for
one resolution (pin management's newest-release pin, §16.24) do not save it.
Because the newest installed bundle is the one that runs and a bundle never
downgrades, switching back to `stable` while a newer pre-release bundle is
installed leaves that pre-release running until a newer release reaches the
channel; self-update says which bundle stays active and why. The saving
behaviour is the host's (§16.11): a host older than the release that introduced
it applies the selection to that run only — so the first self-update from such a
host, which itself runs on the old host, does not save the channel; selecting it
again once the newer host is in place (or setting it through the settings
command) saves it. A pin (§16.21) is
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
are **actually gone from disk** — the removal completing is not by itself
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
are registered. Each provider declares, when it registers, the report **area**
its items belong to (§16.36); a health run narrowed to some areas runs only
their providers.

**Actionable vs informational items.** An item is one of two **kinds**. An
**actionable** item is a nag: something the user can act on, carrying a `remedy`.
An **informational** item affirms a healthy state (for example, that a compiler
cache is in use) and carries no remedy. Both appear in the full health report, but
only actionable items contribute to the compact `N suggestions` count (§16.18,
`spec/ui.md` §1.1) — an affirmative note never inflates the nag total. The report
lists the actionable items first and then the informational ones — grouped
into one section per area (§16.36) — which it renders distinctly — a different bullet, as positive status rather than a
warning — so the bullets a reader counts as suggestions match the count even
without color. The text report is **ASCII** — `*` for an actionable item, `-`
for an informational one, `+` / `x` / `-` / `?` for an inventory entry that is
found / missing and required / missing / unknown, and no typographic dashes or
arrows — because it is read in consoles whose code page renders anything else
as garbage. Item text shared with the editor keeps its own characters there;
only the terminal report folds them. The machine-readable document carries the
item text unchanged.

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
- a **network tier** — the results of the on-demand (network-backed) providers
  (except **report-only** ones, whose items are shown by the health run that
  computed them and never stored — provider #3 below) — stored with the time they were computed and a **running-version key** (the
  running release bundle, the running host binary's release identity (§16.32) and
  the effective update channel, all read locally). It has **no time-to-live**:
  it is only ever written by a health run and only ever read by a passive
  collect, which shows it for information however old. Items recorded under a
  different running-version key (e.g. before a self-update) describe a release
  that is no longer running and are stale regardless of age.

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
- **On-demand health** (`lw health`) is the full refresh and **never reads the
  cache**: every run recomputes the local tier, re-runs the on-demand providers
  (the network tier — back-to-back health runs each make the update check) and
  re-probes the inventory (§16.33), and reports exactly what it just computed.
  The cache is the health run's **output**, not its input: inside a workspace
  it then writes, for the passive consumers, every tier it computed
  **completely** — all three for an unnarrowed run; a run narrowed to some
  areas leaves the tiers it did not compute as they were, and the relevant
  scope writes a partial inventory tier that records what it probed
  (§16.36). There is no flag to force a refresh — every health run is one.

**First run and resilience.** With no cache present, a passive collect computes
only the local tier (never the network); a health run computes everything, as
always. The
cache is advisory and self-healing: a missing, corrupt, or older-schema cache is
treated as empty and recomputed — it never raises an error and never blocks a
render or a health run. Writes are atomic. A passive collect outside a workspace
(no `.nvim/` to key against) simply runs the passive providers directly without
caching, and a health run outside a workspace runs its workspace-independent
providers directly and **persists nothing anywhere** — no workspace cache and no
per-user cache; the next run checks again. No background or
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
change it; there the remedy points at the pin-management upgrade (`lw bootstrap
upgrade`, in the invoked form, §16.24), which moves the pin to the newest release
on the same resolved channel this provider compared against. Version comparison is the same semver-aware ordering used
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
tier and its failure handling (below).

Resolving the newest version is a **network** operation (the releases API for
`unstable`, otherwise a lightweight read of the channel base's manifest to learn
the version it names — never a bundle download, and this availability probe
applies no integrity verification; a real self-update still verifies signature +
hash per §16.12). Because it is network-backed it is on-demand: it never runs on
the passive `N suggestions` count. An unknown channel or an already-current
version yields *no* suggestion and no error output. The network-derived version
is validated before it is displayed and is never interpolated into a URL or path.

**Time budget and offline behaviour.** The health check's fetch is bounded: a
connect timeout of 5 s, 10 s for the whole transfer, and **no retry** — so a
blackholed network (captive portal, half-up VPN, a dropping firewall) costs
`lw health` at most ~10 s instead of the transport's minutes-long default wait.
(Install and self-update keep the default transport behaviour — no time limit,
transient failures retried, §16.12 — since there the download is the operation
the user asked for.) A local-path / mirror source (§16.29) is a file read and is
unaffected. When the check **fails** (offline, server unreachable, HTTP/API
error, malformed answer), health emits one **informational** item "update check
skipped — offline or release server unreachable", its `detail` the first line of
the failure reason — never an error, never counted, so the report does not read
as "up to date" when nothing was checked. Like every network-tier item it is
written to the cache (the health run's fresh result replaces the previous one,
successful or not); the passive count still excludes it (informational).

**Channel override surfaced.** When a release-source location override (a mirror
— `LOOMWORKS_RELEASE_URL` or the `release-url` setting) is in effect *and* a
non-default channel is configured, health reports that the override **supersedes**
the channel (§16.29): the configured channel is effectively ignored, updates
come from the override. This item is network-free (it reads only the resolved
override + channel) but is surfaced in the health view rather than the passive
count. It is the health-view counterpart of the inline self-update warning for
the same state; both derive from the identical override/channel resolution
rather than duplicating it.

**Provider #3 — git submodule drift (on-demand, report-only).** When the
workspace root lies inside a git repository whose top level has a submodule
declaration file (`.gitmodules`), health reports how that repository's
submodules — recursively, nested ones included — stand against what the
repository records. Located by walking up from the workspace root to the
nearest repository marker (a `.git` directory or file) and checking for the
declaration file there, both plain file checks: with no repository, no
declaration file or no `git` executable the provider is silent and spawns
nothing. It is **workspace-scoped**. It reports, per submodule:

- **checkout vs recorded commit** — the commit checked out in the submodule
  against the commit its parent records (the parent's index, as git's own
  submodule status compares): *match*, *ahead* / *behind* by N commits,
  *diverged* (N ahead, M behind), *unrelated* (no common history), *recorded
  commit not present locally* (never fetched), *not initialized*, or
  *conflicted* (an unmerged gitlink);
- **recorded commit vs the tracked branch as last fetched** — for an
  initialized submodule, the recorded commit against the remote-tracking ref of
  the branch it tracks: the declaration file's `branch` for that submodule
  (`.` meaning the parent's current branch), else the remote's default branch
  as last recorded locally (the submodule's `origin/HEAD`). It uses **local refs
  only — never a fetch**, so it is as fresh as the last fetch; a submodule with
  no such ref is not compared. A pin behind reads "N behind origin/<branch>";
  a pin not contained in the branch reads as ahead / diverged (someone may be
  unable to fetch it);
- **reachability of uninitialized submodules' remotes** — the URL an
  initialization would clone (the parent's configured URL for that submodule,
  else the declared one; a relative URL — `./…`, `../…` — resolved against the
  parent repository's `origin` URL, or its working directory when it has none,
  by git's rules) is probed with a remote HEAD query. This is the provider's
  one network operation and is bounded: at most 16 distinct network URLs (and
  64 local-path ones, which are local queries), deduplicated, all network
  probes running **concurrently** under one **10 s** timeout (a real ssh round
  trip to a distant forge was measured at ~4.6 s, so a 5 s budget misreported
  answering remotes), with credential and terminal prompts disabled. Only a
  **definitive** failure (the remote or transport answered with an error)
  marks a URL *unreachable*; a probe that times out leaves it **not
  verified** — a slow network is never reported as a missing remote. A URL
  beginning with `-` is never passed to git (reported as not checked), nor is
  one beyond the caps. Only an explicit health run probes.

Cost: one recursive submodule status query, one index lookup per parent of a
differing checkout (the recorded commits), plus — concurrently, bounded — one
ahead/behind count per differing checkout, one per initialized submodule with
a remote-tracking ref, and the reachability probes; every spawn has a timeout,
so a hung git reads as unknown and never stalls the report. Every git query
runs without optional locks (it never refreshes or rewrites the repository's
index). Everything is local file reads and local git queries except the
network reachability probes. When the status query itself fails or times out,
one informational item says the submodules could not be checked.

Every item is **informational** — never counted in `N suggestions`, never
gating: a checkout ahead of its pin is ordinary work in progress, a pin behind
its branch is often deliberate, and an optional submodule may be left
uninitialized on purpose. Items are terse and grouped, one per kind of finding,
naming the first few submodules and a "+N" for the rest, and pointing at the
verbose report:

- "submodules: N checked out off their recorded commit (<path> 2 behind, …)";
- "submodules: N pins behind their tracked branch (<path> 5 behind
  origin/dev, …)" (ahead / diverged pins included under the same heading);
- "submodules: N not initialized, M nested (…)";
- "submodules: N remotes unreachable (…)";
- "submodules: N remotes did not answer within 10 s — not verified (…)";
- with none of the above: "submodules: N in sync with their recorded commits".

An item's per-submodule detail (one line each, plus the remedy — `git submodule
update --init --recursive` to restore the recorded commits and initialize
missing ones, or `git add <path>` in the parent to record the checked-out
commit) is shown only by the verbose report and carried by the machine-readable
document; the help topic (`lw help submodules`) explains the states. The
provider is **report-only**: its items are not written to the health cache
(nothing passive displays an informational item, and a stored copy would never
be invalidated), and — spawning processes — it never runs on the passive
`N suggestions` path.

**Provider #4 — repo launcher and pin (on-demand, report-only).** When a
version pin (§16.21) is found — by the same upward pin-root discovery the
redirect uses (§16.23), from the workspace root or, outside a workspace, the
current directory — health checks that the launcher files will work for every
contributor and CI runner. It **reports and never fixes**: every remedy is a
command the user runs, usually the **repair** — `lw bootstrap install`, which
keeps the pin (§16.24; `lw bootstrap install --pin-only` in a pin-only
repository) — spelled in the invoked form (§16.24: the launcher form when health
itself runs through a launcher, else the global form). It is **pin-scoped**: it
runs whenever a pin root is found, with or without a workspace, and is silent
when none is.

These checks are **shared with the pin-management status page** (`lw
bootstrap`, §16.24): one implementation produces the findings, their wording
and remedies for both; health adds the `launcher:` prefix. Checks are scoped by
the **launcher mode** (§16.24): in a **pin-only** repository (the pin with
neither launcher) the absent launchers are intended and not reported, and only
the pin-scoped checks run — the pin, its committed state, its attribute, its
committed and checked-out line endings, stale cached binaries.

File checks (local reads, no process spawned):

- **pin** — it parses, its version is safe, and it carries a hash for every
  published host-binary asset and for the bundle; a missing hash is
  **actionable** ("lw.pin has no hash for `<asset>`": that platform cannot run
  the launcher);
- **launchers present** — both launchers exist beside the pin; with exactly one
  present the missing one is **actionable** (with neither, the repository is
  pin-only, above);
- **launcher generation** — each launcher is classified against the catalogue of
  launcher generations (§16.24): the running host's own generation → fine; an
  earlier generation with a known **defect** that breaks runs (e.g. the Windows
  launcher that resolved system tools through the search path, §16.22) →
  **actionable**, naming the defect in a few words; an earlier generation whose
  known differences are only cosmetic or robustness (no retry, noisy progress)
  → **informational** ("lw.cmd is the launcher written by lw `<releases>`,
  older than this lw's: …; refresh it with …"; the defective case reads "…
  written by lw `<releases>`: `<defect>`"); **not a known
  generation** → **actionable** ("lw.cmd differs from every launcher lw wrote
  (local edits?)", remedy: if the edits are not intended, `lw bootstrap install
  --force` restores the generated launcher), since other contributors and CI run
  whatever it does. A generation newer than the running host is reported as not
  recognized, never as defective.

Version-control checks, only when the pin root is inside a git working tree
and `git` is available (else silently skipped). A few local queries, each under
a timeout, run without optional locks (never refreshing the index):

- **committed** — the pin, the launchers and the metadata files pin management
  writes (the root ignore and attributes files; in a pin-only repository the pin
  and the attributes file) are committed: one **actionable** item names each
  one that is untracked, staged but never committed, modified or deleted
  relative to the last commit ("not committed yet: lw.pin (modified), lw.sh
  (staged, new), .gitignore (untracked)"; remedy: `git add <files> && git
  commit`);
- **executable bit** — the POSIX launcher's **index** mode is `100755`; `100644`
  is **actionable** ("lw.sh is not executable in git — CI on Linux/macOS cannot
  run it"; remedy: the repair, or `git update-index --chmod=+x lw.sh`, then
  commit);
- **line-ending attributes** — the effective attributes give the POSIX launcher
  and the pin `text eol=lf` and the Windows launcher `text eol=crlf`; a missing
  or contrary rule is **actionable** (remedy: the repair); and the rules that
  are effective come from **committed** content — the attributes as the last
  commit's tree gives them — else **actionable** ("line-ending rules for … are
  not committed yet (.gitattributes)"; remedy: commit it). With no commit yet
  every rule is uncommitted; a git too old to evaluate attributes from a commit
  skips this part;
- **committed line endings** — the index copy of each file is LF-only (a text
  file stored with CR LF or mixed endings will be checked out wrongly on some
  platform) → otherwise **actionable** (remedy: `git add --renormalize lw.sh
  lw.cmd lw.pin` once the attributes are in place, then commit); and the
  working copy has the ending its launcher needs (POSIX launcher and pin LF,
  Windows launcher CRLF) → otherwise **actionable** ("lw.sh has CRLF line
  endings in this checkout — sh will fail"; remedy: re-checkout the file once
  the attributes are in place);
- **ignore rule** — the launcher cache directory is ignored by a committed
  rule of the repository: the matching line is in the committed content of a
  tracked ignore file inside the work tree, not only in a personal or
  repository-local exclude, and not only in an untracked, staged or modified
  ignore file (the same test pin management applies, §16.24); otherwise
  **actionable** — "`.nvim/cache/` is ignored only by an uncommitted rule in
  `<file>`" (remedy: commit it), or "… ignored only by an uncommitted or
  personal rule (your global gitignore or .git/info/exclude) — others will see
  downloaded binaries as untracked", or "… is not ignored".

When every check passes, one **informational** line affirms it ("launcher: lw
`<version>` pinned; lw.sh / lw.cmd current, modes and line endings ok"; in a
pin-only repository "launcher: lw `<version>` pinned (pin only, no launchers);
lw.pin line endings ok"). Stale cached binaries in the launcher cache are
**informational** ("N old pinned binaries in .nvim/cache (`<size>`) — removed by
the next lw bootstrap install").

Items follow the report's conventions: one terse line each under a
`launcher:` prefix, grouped, the detail and remedies in the verbose report and
the machine-readable document, the explanation in a help topic (`lw help
launcher`, also reachable as `lw help pin`). Being **report-only** (it spawns
processes and reads files outside resolved state), it never runs on the passive
`N suggestions` path and writes nothing to the health cache; its actionable
items are listed with the report's other actionable items but, like provider
#3's, never reach the passive count.

**Health runs without a workspace.** A provider is either **workspace-scoped**
(it inspects the resolved workspace — e.g. the compiler-cache provider) or
**workspace-independent** (it ignores the workspace — the update-availability and
channel-override providers, which concern the running `lw` release itself). When
health is invoked outside a configured workspace, the workspace-independent
providers still run and report; the workspace-scoped ones simply contribute
nothing. So `lw health` in a plain directory still surfaces an available update or
a channel override — it does not fall silent merely because no workspace is
loaded. The report leads with the same worktree/init hint the status overview
shows (§16.18) so the absence of project-scoped items is explained. Outside a
workspace plain `lw health` reports only the `lw` and `launcher` areas and
probes no toolchain, SDK or editor declaration; the machine inventory is
`lw health --all` (§16.36). A refused working copy (§17.4) is reported as an
actionable item and health continues as outside a workspace (§16.36).

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
system-Lua source (§16.11), the active bundle (marked as a pre-release when it
is one, e.g. `bundle: 0.1.40-beta.1 (prerelease)`), and the channel (§16.29). In
pinned context (§16.22) the **pin**, not the channel setting, decides what runs,
so the report shows the pinned version, marked as a prerelease when it is one,
and the pin file it runs under (`pinned: 0.1.36-beta.1 (prerelease) by
<root>/lw.pin`) instead of the channel; a user who invoked a launcher can so
confirm which pin and which binary answered. The environment inventory's entry
for the running release (§16.33) likewise reads "pinned by lw.pin" (plus
"prerelease"). The report
is ASCII (§16.7). A host with no release version never reports a guessed version: a development
build reports that it is one, and a release host with no version identity
(released before identity existed) reports its release as unknown. The
distinction uses the same development-build determination as host
replacement below, so a host reported as a development build is never
replaced and one reported as an unknown release is. The active bundle is
reported truthfully: a host that resolved no system-Lua source and carries
none built in (a release host before its first acquisition, §16.13) reports
that no bundle is installed and names the acquisition operation, never a
bundle it does not have — the same condition every other command reports as
"no release installed".

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

**What's new.** When self-update installs a bundle newer than the one that was
running, it then says what changed between the two, from the release notes the
new bundle carries (§16.37) — never from the network, and never from notes the
old bundle carries. The host reads the notes file and the renderer from the
newly installed, already verified bundle and prints, per release between the
old and the new version (newest first): the version and its summary, then its
`Breaking` and `Upgrade notes` items (at most three per release, then a count
of the rest); at most five releases (then a count of the rest), and a closing
line naming the command for the full notes (`lw release-notes --since <old
version>`), printed after the host-binary line so it is the last thing
self-update prints. The lines are ASCII (§16.7) and wrapped to the terminal. When
standard output is not a terminal, or the run is non-interactive, a single
line is printed instead, naming the same command (`lw: what's new since <old>:
lw release-notes --since <old>`). Nothing is printed for a first installation
(no previous bundle), for a re-installation of the same version, or when
release notes are silenced (§16.37); any failure to read or render the notes
reduces the output to that single line and never changes the exit status. Printing any of it records the new version as seen (§16.37). This
is host behavior (§16.11): a host that predates it prints nothing here, and
the upgrade notice (§16.37) covers that update instead.

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
nothing and changes no selection. The whole inventory is the **full** scope
(`lw health --all`); plain `lw health` probes and lists only what the
workspace makes relevant, and either can be narrowed to areas (§16.36).

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
*other*. Each category maps to a report **area** (§16.36). A declaration may
also carry, optionally, an `area` (overriding the mapping) and `languages` (it
is then relevant only in a workspace with one of those languages, §16.36). `probe(ctx, done)` resolves to one or more **results** — an enumerating
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
  enumeration was inconclusive reads as unknown, never as missing; and it may
  name **alternatives** — other ids that satisfy it equally (e.g. a copy of the
  executable that the build's own environment provides): when its own id is not
  found, the first alternative that is found is the required entry instead (the
  report shows what the build will actually use), and only when none is found
  does the requirement read as missing under its own id;
- a profile that pins an SDK installation requires it (§10.4);
- a project whose module type is not loaded (missing or rejected) requires that
  module — its plugin-registry entry.

A workspace with no profiles at all scopes its requirements to every project
(with no tool), so a module's own executable is still required.

The requirement scope follows the compiler-cache provider (§16.31): the **active
profile's** projects and tools, or — with **no active profile** — the union over
**every profile**, each requirement naming the profiles and projects that need
it. What non-active profiles need is not *required* but is still **relevant**
(§16.36): relevance is evaluated over every profile. Compiler-cache launchers
are never listed as required here — whether a
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
health run**, which always re-probes (a health run never reads the cache back,
§16.31). Its results are stored in the health cache (§16.31) as a third tier
beside the local and network tiers:

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

A relevant-scope health run (§16.36) writes a **partial** tier: the results of
the declarations it probed and the list of **contributors** it probed (a tier
without that list was written by a full probe). A requirement of a contributor
the tier did not probe reads as **not checked** — neither missing nor counted.
The partial tier came with a bump of the inventory key version, so neither
reader trusts a tier recorded under the other meaning.

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

**Rendering.** *(The layout below is superseded by the area sections of
§16.36: the Required / Other split becomes, per area, required and relevant
entries first and — in the full scope only — a compacted "not used here"
line; the line format and marks are unchanged.)* Terse, one line per result:
a status mark — `✓` found, `✗`
missing and required, `–` missing and not required, `?` unknown — the label,
version, and location — or, for a missing result, its `hint`. Inside a workspace the
actionable suggestions come first (§16.31), then **Required by this workspace**
(one line per item, naming what needs it — compacted so the line never wraps:
a single name as is, one profile's several projects as that profile with a
project count, several profiles or projects as their count with as many names
as fit a short budget and a "+N" for the rest; the verbose flag and the JSON
carry every name), then **Other**, compacted to one line
per category (found items with versions, missing ones marked), then one `lw`
line. Outside a workspace there is no split: after the init hint (§16.31) every
category is listed one line per item. A verbose flag expands **Other** to one
line per item with locations.

**Machine-readable output.** A JSON flag prints one document instead of the
report: `{ schema, workspace?, suggestions[], inventory[], summary, update?,
submodules? }` — `workspace` is
`{ name, root }` when there is one, each suggestion is `{ kind, title, detail?,
remedy? }` (the full health list, actionable and informational), and each
inventory entry is a result plus `category`, `required` (boolean) and
`required_by` (profile/project names, never compacted); `hint` is carried only by an entry that is
not found (a found item's install remedy is noise). `summary` counts
`{ required_missing, actionable, found, missing, unknown }` — the missing
required entries, the actionable suggestions, and the inventory entries by
status — so a script need not recount. `update` is the update check's outcome
(§16.31): `{ status, channel, current, newest?, detail? }` with `status`
`available` (a newer release exists), `current` (up to date) or `unknown` (the
check failed — `detail` says why); it is absent when the check does not apply
(a development / fused source or an unknown channel). `submodules` is the
submodule provider's report (§16.31), absent when it does not apply (no
repository, no declaration file, no `git`): `{ root, entries[], error? }`, `root` the
repository's top level and each entry `{ path, name?, nested, state,
recorded?, checked_out?, ahead?, behind?, tracking?, url?, reach?, reachable? }` —
`path` relative to `root`, `state` one of `match`, `ahead`, `behind`,
`diverged`, `unrelated`, `missing-commit`, `uninitialized`, `conflict`,
`unknown`; `tracking` `{ ref, ahead, behind }` compares the recorded commit
with the tracked branch's remote-tracking ref; `url` is the resolved URL of an
uninitialized entry, `reach` its probe outcome (`reachable`, `unreachable`,
`no-answer`, `not-checked`) and `reachable` a boolean present only for a
definitive answer; `error` is set when the status query failed. Informational
only — it never affects `summary`. Object keys are emitted in
sorted order at every depth and arrays in their defined order (inventory: category
order, then declaration order), so the same data prints byte-identically — stable
for scripts and CI diffs. It carries the same data as the text report, is
versioned by `schema`, and exits 0 like the report — health never fails. The
document follows the run's scope and area selection and carries, additively
under the same `schema`, `scope`, `areas?`, `hidden?`, each suggestion's
`area` and each inventory entry's `area`, `relevant` and `used_by?`
(§16.36); `summary` counts what the document holds. There
is no check mode that exits non-zero on a missing required item in this version
(suggestions are advisory, §16.31); CI can test `required && status ==
"missing"` in the JSON (or `summary.required_missing`).

**Editor.** The editor status page's count reads the same cache, so it reflects
missing required items once a health run has recorded them. An editor-native
health rendering of the inventory is deferred (the probes are host-neutral, so
it can later render the same results).

**Out of scope for this version:** minimum-version requirements (a found tool
that is too old reads as found); installing or repairing anything; editor-only
registry lookups; a per-user cross-workspace cache; a non-zero check mode; an
editor-native health rendering; probing on any path other than an explicit
health run.

### 16.34 Device commands

The standalone host exposes devices and remote execution for scripting and
CI. All device commands resolve runners from the SDKs in scope: the resolved
profile's SDK when a profile resolves, otherwise every declared SDK whose
provider supplies a device runner.

- **List** (`lw device list [--json]`) — the attached devices each runner
  reports: serial, state, runner id, display name (the runner's
  `describe_device` result when it offers one, §18.2, else its listing's name,
  else the serial), and whether the serial is a profile's persisted device. Read-only; exits 0 with an empty list when
  nothing is attached, non-zero only when no runner is available.
- **Device block** (`lw project set <project> device.stage|device.archive
  <glob>…`, `device.working_dir <dir>`, `device.env.<NAME> <value>`; `lw project
  unset <project> device[.<field>[.<NAME>]]`) — edit the project's device block
  (§18.9) in the working copy, a management operation (§16.9). A glob list
  replaces the previous one; the result is validated like a loaded block and a
  denied environment variable (§17.9) is refused.
- **Select** (`lw device select <serial> [profile]`) — persist the serial as
  the profile's device (§1.8), a management operation writing the working copy
  (§16.9). `--clear` removes it.
- **Named test executables** — `lw test [profile] --target <t> [--target <t>…]
  [--junit <file>] [-- <args>]` runs the named executables per §16.16 (on a
  device when foreign); `<args>` go to each executable (e.g. a test filter).
- **Per-invocation selection** — `run` and `test` accept `--device <serial>`
  (§18.3 rule 1). It is never persisted.
- **Staging control** — `run` and `test` accept `--fresh` (re-stage every
  file, ignoring the sync record, §18.4). `lw device clean [--device <serial>]`
  removes this workspace's staging root from the device (§18.12), then the
  runner's staging base when that left it empty (an empty-directory removal
  only), and clears the host's sync record for that device and workspace,
  saying so.
- **Timeouts** — `run` and `test` accept `--timeout <seconds>` for the device
  program (§18.8). `--query-timeout <seconds>` and `--transfer-timeout
  <seconds>` override the transport timeouts for this invocation (over the
  runner's and core's defaults, §18.8).
- **Log options** — `run` and `test` accept `--log <key>=<value>`, repeatable,
  forwarded verbatim to the device runner over the launch configuration's
  `device_log` table (§18.13). The host knows no option names; the runner
  rejects unknown keys or values with an error before anything is staged.
- **Run folder** — each remote run saves `output.log` (the program's output,
  unfiltered; a single combined stream when the connector merges standard
  error), `device.log` (the runner log stream as kept by the runner), pulled
  result files and crash reports under `<build dir>/.device-runs/`; the ten
  newest per ConfigUnit are kept (§18.5).
- **Lock** — device operations wait for the device lock (§18.7);
  `--no-wait` fails fast instead, naming the holder. `lw unlock --device
  <serial>` clears a device lock immediately. `LOOMWORKS_DEVICE_LOCK_DIR`
  relocates the lock directory (§18.7).

Resolution is non-interactive in every host that cannot prompt: ambiguity is an
error listing the candidates and the option that resolves it.

Example (illustrative names):

```
$ lw device list
SERIAL              STATE   RUNNER  NAME
FMR0225108000951    online  ohos    Mate 60 Pro   (device for Debug:ohos-openharmony-arm64-v8a)

$ lw run Debug:ohos-openharmony-arm64-v8a LumeSceneAPITestRunner -- --gtest_filter=Scene.*
lw: building LumeSceneAPITestRunner … done
lw: staging on FMR0225108000951: 3 changed files (1.2 MB), 51 MB archive unchanged
[==========] Running 12 tests from 1 test suite.
…
[  PASSED  ] 12 tests.
$ echo $?
0
```

### 16.35 Descriptions

Every describable item (§1.10) has one **describe** operation. It reads the
description by default, and writes it when given text or asked to clear.
Writing is a management operation (§16.9). It never runs during a build, and it
lands in the working copy under the working-copy model (§2.4).

**Command shape.** `describe` is a sub-command of each item's command group, so
it takes the same operand as that group's other sub-commands:

```
lw project   describe <project>          [<text> | -m <para>... | -F <file> | -F - | - | -e | --clear]
lw config    describe <project> <config> [same]
lw configset describe <set>              [same]
lw profile   describe <profile>          [same]
lw launch    describe <project> <name>   [same]
```

- `lw launch describe` takes the launch as `<project> <name>` or as
  `--project <p> --launch <n>`. The single-operand `[<project>:]<name>` form
  that `launch show` / `set` / `remove` accept is **not** accepted here: a
  following `<text>` operand would be ambiguous with it.

- `<profile>` resolves like every profile operand (§16.3: list number, exact
  key, unique substring). It is **required**. `describe` never defaults to the
  active profile, so a description cannot land on the wrong profile by accident.
- `lw config set <project> <config> description <text>` and
  `lw config unset <project> <config> description` are accepted as well.
  `description` is a generic field of the configuration param grammar (§16.9),
  so they behave exactly like `describe` with `<text>` and `--clear`.
- Item-creating verbs (`project add`, `config add`, `configset create`,
  `profile create`) accept `-m <para>` (repeatable) to create the item already
  described.
- `lw launch add` takes the description as `--description <para>`
  (repeatable, joined like `-m`). It does **not** take `-m`. Everything after a
  launch's command operand is the program's own arguments, where `-m` is
  common (`python -m http.server`), so `-m` there would change what runs.

**Reading.** With no text source and no `--clear`, `describe` prints the full
description (summary, blank line, body) and exits 0. An item without a
description prints nothing on stdout and says `<kind> '<name>' has no
description` on stderr, and also exits 0. A generated configuration prints its
read-only default description (§1.10) and marks it as coming from the project
files. Reading is read-only and allowed in a non-interactive host. `--json`
prints the item as an object instead:

```
{ "kind": "profile", "name": "Debug:ninja-gcc-12",
  "description": "…full text…", "summary": "…", "source": "workspace" }
```

`description` and `summary` are `null` when there is none. `source` is
`"workspace"`, or `"project-files"` for a generated configuration's default.
JSON strings carry the text exactly (JSON-escaped), so scripts get the stored
bytes, not the terminal rendering.

**Text sources for writing.** They follow git, and exactly one is allowed:

| Source | Meaning |
|--|--|
| `<text>` | The whole description, one operand. Newlines inside it (shell quoting) are kept |
| `-m <para>` | Repeatable. Each `-m` is one paragraph, and paragraphs are joined by a blank line. The first `-m` is therefore the summary |
| `-F <file>` | Read the description from a file |
| `-F -`, or a lone `-` operand | Read the description from standard input, to EOF |
| `-e`, `--edit` | Open an editor (below) |
| `--clear` | Remove the description |

Combining two sources, or `--clear` with a source, is a usage error. `-e` may be
combined with `-m`, `-F` or `<text>`, which then pre-fill the editor, as in git.

**Editor.** `-e` opens `$VISUAL`, then `$EDITOR`, on a temporary file. The file
is pre-filled with the current description (or the pre-fill), followed by
comment lines starting with `#` that name the item and explain the format. On
save, the `#` lines are removed (the stored text is never commented) and the
result is normalised (§1.10). If the editor exits non-zero, the edit is aborted
and nothing is written. If neither variable is set, the command is an error that
names the scriptable forms. In a non-interactive host (§16.3: `--no-input`,
`LW_NO_INPUT`, `CI`, or stdin not a terminal), `-e` is an error that names the
scriptable forms. `-m`, `-F`, `<text>` and `--clear` work non-interactively.
Reading standard input with `-F -` is data, not a prompt, so it is allowed under
`--no-input`.

**Writing.**

- The text is normalised (§1.10). If the result is empty, the description is
  **removed**: `""`, `-m ""`, empty stdin and an editor saved empty all clear it,
  exactly like `--clear`. A write that changes nothing writes nothing and says so
  (`(unchanged)` / `… has no description`), then exits 0 (§16.9).
- A description containing a control character other than LF and TAB, or longer
  than 4096 bytes, is refused. It exits 1 and writes nothing.
- A generated configuration is refused, with a pointer to
  `lw config add <project> <name> <generated-config>` (§1.10).
- Describing a `shared` item materialises it (§2.4, implicit cascade on use).
  The publish reminder is printed only when a `loomworks.json` exists and the
  change reaches it, as for every other edit (§16.9). A local-only workspace
  never shows it.

**Display in one-line views.** Every listing and status row that names a
describable item shows its **summary**, dimmed on a colour terminal. This covers
the status overview's profile, configuration set and project rows (§16.18),
`lw profile list`, `lw project list`, `lw config list` and
`lw configset list`. Every such row follows **one layout rule**:

1. identity and fixed-width columns first;
2. then the summary;
3. then any **open-ended list**, which takes the truncation. Examples of such
   a list are a set's project→configuration mappings and a project's
   configuration names.

The summary is fitted as follows:

- **Rows with an open-ended tail** (`lw configset list`, and the status
  overview's configuration-set and project rows):
  - The summaries form one column, as wide as the longest summary shown and
    **at most 36 columns**. Rows without a description leave it blank, so the
    lists after it stay aligned.
  - On a terminal, the list is cut with `…` to the width that remains.
  - When fewer than 16 columns would remain for the summary column, the
    summaries move onto continuation lines beneath their rows, indented and
    capped at 60 columns. The list then stays on the row.
  - When standard output is not a terminal, a listing that prints its
    open-ended list in full (`lw configset list`, and `lw launch list`'s
    `RUNS`) prints the summaries in full too: the column is as wide as the
    longest summary, with no cap and no `…`. The status overview's rows, whose
    lists stay cut, keep the 36-column cap.
- **Rows without an open-ended tail** (`lw project list`, `lw config list`,
  `lw profile list`, the status overview's profile rows):
  - The summary ends the row. Its width is the terminal width (§16.18, the
    same source as other fitted columns) minus the row's other columns and a
    two-column gap, and **at most 60 columns**. When standard output is not a
    terminal, the cap alone applies.
  - When fewer than 16 columns remain, the summary moves onto a continuation
    line beneath the row, indented and capped at 60 columns.
  - A listing whose rows already span two lines (`lw profile list`) puts it at
    the end of the first line.
- **Truncation.** The summary, and the open-ended list it precedes, are
  measured and cut in **display columns** (code points, with wide characters
  counted as two), never bytes. A cut ends in `…`. A summary is never dropped
  silently.

**Launch configurations and targets in one-line views.**
- `lw launch list` follows the layout rule above. `PROJECT` and `NAME` are the
  identity columns, then a `DESCRIPTION` column (the summary column; the header
  appears only when some launch has a description), then `RUNS`.
  - `RUNS` is the open-ended tail: `target:<t>` or the command, then the args.
    On a terminal it is cut with `…` to the remaining width, instead of today's
    fixed 46 bytes. When stdout is not a terminal it is printed in full, and
    so is the `DESCRIPTION` summary (no 36-column cap).
  - The full args are always in `lw launch show`.
- `lw target list` rows (`* <project>:<name> (launch|exe)`) and the status
  overview's and `lw profile show`'s Targets rows end in a bounded kind label,
  so a launch's summary ends the row, fitted as above (at most 60 columns). A
  build target (`exe`) has no description.
- Messages that list candidates, such as an ambiguous `lw run` operand, keep
  their `project:name (kind)` form without summaries.

**Display in detail views.** `lw project show`, `lw config show`,
`lw configset show`, `lw profile show` and `lw launch show` print the **full** description, one
output line per description line, indented under a `description` label. It comes
right after the item's header or identity lines, and a detail view never
truncates it. `lw profile show` also shows its configuration set's summary on
the configuration-set line. `lw config show` no longer lists a description as a
module field. All output follows §16.7 and §17.11.

`lw profile query` is unchanged: its fields are per `(profile, project)` build
facts, and a description is neither per-project nor a build fact. Scripts read
descriptions with `describe --json`. For a launch configuration,
`lw launch describe … --json` reports `"kind": "launch"`, `"project"`, `"name"`,
`"description"`, `"summary"` and `"source": "workspace"`.

`lw launch show <project> <name> --json` prints the launch configuration as one
object, for scripts that need to tell launches apart:
- `project`, `name` and `kind` (`"target"` or `"command"`);
- `target` or `command`, `args` (an array, never joined), `working_dir`, `env`;
- `deploy`, `device`, `device_log` and `debug` when set;
- `description` and `summary` (`null` when absent).

Values are as declared, not expanded. Its human form lists `description` first,
then the fields it prints today, then `deploy`, `device` and `debug`, which it
did not show before.

Example:

```
$ lw profile describe dev-clang -m "Clang debug build with ASan" \
      -m "Use this one for the nightly sanitizer run; needs clang >= 18."
profile 'Debug:ninja-clang-18.1.0' described
`lw publish` to update the shared loomworks.json.   (only when it reaches loomworks.json)

$ lw profile list
* 1  Debug:ninja-clang-18.1.0   Clang debug build with ASan
       set=Debug tools=[ninja-clang-18.1.0]
  2  Release:ninja-gcc-12       Optimised build used for release packagi…
       set=Release tools=[ninja-gcc-12]

$ lw configset list
  Debug              Clang debug, ASan on CI     App→Debug, Lib→Debug
  Release            What CI ships               App→Release, Lib→Release, Tools→R…

$ lw launch describe LumeEditor schema-test -m "Editor with the scene JSON schema test data"
launch configuration 'LumeEditor:schema-test' described

$ lw launch list
Launch configs — pass PROJECT and NAME to `lw launch show|set`:

  PROJECT     NAME         DESCRIPTION                          RUNS
  LumeEditor  editor       Plain editor                         target:LumeEditor
  LumeEditor  schema-test  Editor with the scene JSON schema t…  target:LumeEditor --use-scene-json-sc…
  LumeEditor  theme-demo   Theme showcase scene                 target:LumeEditor --theme demo

$ lw launch rename LumeEditor schema-test scene-schema
renamed launch configuration 'LumeEditor:schema-test' -> 'LumeEditor:scene-schema'
  default target updated in profiles: Debug:msvc-17, Release:msvc-17

$ lw target
* LumeEditor:editor (launch)        Plain editor
  LumeEditor:scene-schema (launch)  Editor with the scene JSON schema test data
  LumeEditor:LumeEditor (exe)

$ lw profile describe 1 --clear
profile 'Debug:ninja-clang-18.1.0': description removed
```

### 16.36 Health scope and areas

*(Proposed — amends §16.31 and §16.33.)* A health run has a **scope** and an
optional **area selection**. Plain `lw health` reports only what concerns the
current workspace (the **relevant** scope); `lw health --all` reports every
check (the **full** scope — the report §16.31 and §16.33 describe), with the
workspace-relevant items still marked. Either scope can be narrowed to one or
more **areas**.

**Areas.** Every health item — a suggestion (§16.31) or an inventory result
(§16.33) — belongs to exactly one **area**, from a fixed, core-owned set that
also fixes the report order:

| Area | Contents |
|--|--|
| `lw` | the running `lw` release and host binary, the update check, the channel override, the plugin registry (inventory categories *lw*, *plugins*) |
| `workspace` | the workspace's own state: a refused working copy (below) and any future workspace-level provider |
| `toolchains` | build-system executables and compilers (inventory categories *build tools*, *compilers*) |
| `cache` | compiler caches: the compiler-cache and cache-compatibility providers (§16.31) and the *compiler caches* inventory category |
| `sdks` | SDK installations (inventory category *SDKs*) |
| `editor` | language servers and debug adapters (inventory categories *language servers*, *debug adapters*) — used only by the editor |
| `launcher` | the repo launcher and pin checks (§16.31 provider #4) |
| `submodules` | the submodule drift report (§16.31 provider #3) |

An inventory result's area follows from its declaration's `category` by the
table above, unless the declaration names an `area` itself (§8.4); an
unrecognized category or area renders under a trailing `other` area. The
inventory `category` keeps its meaning (§16.33): a finer grouping *within* an
area, shown as the label column of the area's lines. A suggestion provider
declares its area when it registers (an item may override it); a provider
registered without one runs under every selection and renders under `other`.
The area names are CLI surface: adding an area is additive, renaming or
removing one is not.

**Relevance.** Relevance is computed over the **whole workspace** — every
profile, not only the active one (with no profiles, every project) — so that
switching the active profile never turns a needed item irrelevant. The
active-profile scope of *required* (§16.33) is unchanged. A **contributor**
(§16.33) is relevant when it is:

- a **module** that some project of the workspace has as its type (a project
  whose module is not loaded makes that module's plugin-registry entry
  relevant, as its requirement already does, §16.33);
- an **SDK provider** of which some profile pins an installation;
- a **language-server inventory companion** whose server some module of the
  workspace names in its `lsp_servers` (§8.4) — or, when none of the
  workspace's modules declares `lsp_servers`, whose declared `languages`
  (§9.3) intersect the **workspace languages**: the effective languages (§1)
  of every configuration of every project;
- a **debug-adapter inventory companion** whose declared `languages`
  intersect the workspace languages;
- **core** — its `lw` and plugin-registry declarations always; its
  compiler-cache launcher declarations when the workspace has a project whose
  module reports the caching-relevant language (the compiler-cache provider's
  own predicate, §16.31); its SDK-provider declaration under the SDK-provider
  rule above.

A declaration that carries `languages` (§8.4) is relevant only when they also
intersect the workspace languages, whatever its contributor.

An inventory **result** is relevant when it is **required under the whole
workspace** (the §16.33 requirement evaluation over every profile, an
alternative that binds included); or it comes from a declaration relevant as a
whole — the `lw` entry, a matched companion's results, the compiler-cache
launchers; or it is a plugin-registry entry that the workspace uses or that is
**rejected** (a rejected plugin is a problem of the installation, reported
wherever `lw` runs). Every other result of a relevant declaration is
**hidden**: an installation an enumerating declaration found that no profile
uses (another compiler, another toolchain installation, an SDK installation
detected but not pinned), a loaded plugin the workspace does not use.

Every **suggestion** a provider emits is relevant: providers are self-scoping
— they return nothing when their subject is absent (no project with the
caching-relevant language, no pin, no submodule declaration file, no
workspace). A **missing required** item is therefore always relevant: the
relevant scope never hides an actionable item that the full scope shows,
except through an area selection that excludes its area.

**Selection syntax.** `lw health [<area>...] [--all] [--verbose] [--json]`.
Areas are positional, in any order, deduplicated; with none given, every area
is selected. An unknown area is a usage error naming the valid ones — the one
case in which `lw health` exits non-zero, because nothing was checked. Shell
completion offers the areas not yet given plus the flags; `lw help health`
lists the areas, one line each.

**What runs.** Scope and selection decide what is computed, not only what is
printed:

- **skipped** (never probed, never run): in the relevant scope, every
  declaration of a contributor that is not relevant — an unused module's
  executables, the installation enumeration of an SDK provider nothing pins, a
  companion for a server or language the workspace does not use, the
  compiler-cache launchers in a workspace without the caching-relevant
  language; under an area selection, every provider and declaration outside
  the selected areas — so `lw health launcher` makes no network request and
  probes nothing;
- **hidden** (run, not shown): the non-relevant results of a relevant
  enumerating declaration — the scan that finds the compiler a profile uses
  finds the others too; they are counted, not listed;
- **always run** when their area is selected: the local providers (cheap and
  self-scoping), the update check and the channel override (they concern the
  running release, which every workspace uses), and the launcher and submodule
  providers when their subject exists.

Declarations are still **built** for every contributor — building is cheap by
contract (§8.4: no spawn, no scan) — so the hidden count includes the skipped
ones.

**Hidden count.** Without `--all`, the report ends with one line counting what
the relevant scope left out, per area in area order: "N other checks not
relevant here (<area> n, …) — lw health --all" (with the area selection
repeated in the pointer when one was given). A skipped declaration counts
once; a hidden result counts once. The line is omitted when nothing was left
out.

**Outside a workspace** — and with a refused working copy, below — nothing is
relevant but `lw` itself. Plain `lw health` then reports, after the worktree
hint (§16.31), the `lw` area (the running release, the update check, the
channel override, rejected plugins) and the `launcher` area when a pin is
found from the current directory. It probes **no** toolchain, SDK or editor
declaration and ends with "Machine inventory not checked outside a workspace
— lw health --all lists toolchains, compiler caches, SDKs and editor tools."
`lw health --all` outside a workspace is the full machine inventory (§16.33,
no required split), grouped by area. Nothing is cached in either case
(§16.31).

**Refused working copy.** When the workspace's working copy is refused
(§17.4), health does not stop at the refusal the way a workspace-requiring
command does: it reports an **actionable** `workspace` item — title "working
copy not trusted (.nvim/loomworks.user.json <not signed by this machine |
modified outside loomworks>)", remedy "review and trust it: lw trust (or
discard it: lw trust --discard; lw help trust)" — and continues as outside a workspace (nothing of the refused file is read,
§17.4; nothing is cached). A trusted workspace has no `workspace` item.

**Rendering.** The report is, in order:

1. the heading (workspace name and root) or the worktree hint;
2. the **actionable** items of every selected area, each ending with its area
   in brackets (`* No compiler cache found  [cache]`) — still first and still
   the only `*` bullets, so they match the `N suggestions` count (§16.31);
3. one **section per selected area**, in area order, headed by the area name,
   holding that area's informational items (`-`) and then its inventory lines.
   An area with nothing to show is omitted, except that an explicitly selected
   area prints "nothing to report". The loaded plugins the workspace uses
   are one line ("plugins + N loaded (<names>)"); a rejected or missing one
   gets its own line. The `lw` section always starts with the
   release line. Required entries come first; a relevant entry that only
   non-active profiles need is marked like a non-required one (`+`, `-`, `?`)
   and names them ("- other profiles: asan"); `x` stays reserved for missing
   **required**;
4. in the full scope, each area's non-relevant entries follow its relevant
   ones, compacted to one line per inventory category under "not used here"
   (`--verbose` lists them one per line with locations), so relevance stays
   visible in `--all`;
5. the hidden-count line (relevant scope only).

**Exit status.** Unchanged: `lw health` exits 0 whatever it finds (§16.31,
§16.33); only a usage error exits non-zero. There is still no check mode. A
hidden item contributes to no count — not the `summary`, not the passive
`N suggestions` count; should a check mode be added later, it considers the
shown items only.

**Machine-readable output.** `--json` follows the same scope and selection as
the text report. Its document gains, additively and without a `schema` bump
(§16.33):

- `scope` — `"relevant"` or `"all"`;
- `areas` — the selected area names, present only when a selection was given;
- on every suggestion, `area`; on every inventory entry, `area`, `relevant`
  (boolean) and — for a relevant entry that only non-active profiles need —
  `used_by` (those profiles/projects, never compacted);
- `hidden` — `{ <area>: count }`, the hidden-count line's figures, present
  only in the relevant scope and only when something was left out.

`summary` counts what is **in the document** (so a script need not recount
what it received). `summary.required_missing` is the same in both scopes,
since a missing required entry is always relevant — unless an area selection
excludes its area. A consumer that needs every entry uses `--all --json`.

**Caching.** A health run still never reads the health cache (§16.31). A tier
is written only when this run computed it **completely**, and is otherwise
left as it was:

- the **local tier** when the `cache` area was selected (its providers ran);
- the **network tier** when the `lw` area was selected (the update check ran);
- the **inventory tier** when no area selection was given — the full scope
  writes every result, as before; the relevant scope writes the results of
  the relevant declarations together with the **contributors it probed**. An
  area-selected run writes no inventory tier.

A passive collect evaluating a partial inventory tier (§16.33) reads a
requirement whose contributor that tier did not probe as **not checked** —
neither missing nor counted — so a project added since the last health run,
of a module nothing probed, never produces a false "not found"; the next
`lw health` probes it (it is relevant then). A tier with no contributor list
was written by a full probe. The inventory key version (§16.33) is bumped with
this change, so a tier recorded under the old meaning is not trusted by a new
reader, nor a partial tier by an old one (it then counts nothing until the
next health run).

**Plugin contract.** The relevance inputs are optional, static and additive: a
declaration's `area` and `languages` (§8.4), a module's `lsp_servers` (§8.4),
an inventory companion's `languages` (§9.3). A plugin that declares none keeps
working — its module declarations are relevant whenever the module is used; a
companion without `languages` that no module names is shown only in the full
scope. None of them bumps `api_versions` (§8.0). Modules and SDK providers
contribute to health only through declarations and requirements; the
suggestion-provider registration (§16.31) is core-internal and not a plugin
contract.

**Editor.** The editor has no health rendering of its own (§16.33); its status
page's count reads the cache through the passive collect (§16.31,
`spec/ui.md` §1.1), which this section changes only through the not-checked
rule above. Scope and area selection are CLI concerns; the providers and the
relevance evaluation are host-neutral, so a future editor rendering applies
the same rules.

```
Example — a cmake workspace on Windows: profiles `dev` (active; Ninja + MSVC,
projects app and lib) and `asan` (Ninja + clang-cl); a version pin and three
submodules; meson, typescript and shell modules, an SDK provider and a
js-debug companion installed but unused.

$ lw health
loomworks health - myapp  (C:\src\myapp)

* No compiler cache found                                           [cache]
  install sccache, then opt in for MSVC-style compilers (lw help cache)

lw
  lw 0.1.39  C:\Users\me\.local\bin\lw.exe
  - update check skipped - offline or release server unreachable
toolchains
  build tools  + cmake 3.30.2             C:\Program Files\CMake\bin\cmake.exe  - dev (2 projects)
               + ninja 1.12.1             C:\tools\ninja.exe  - dev (2 projects)
  compilers    + MSVC 14.40 (VS 2022)     C:\Program Files\Microsoft Visual Studio\2022\Community  - dev (2 projects)
               + clang-cl 18.1.8          C:\Program Files\LLVM\bin\clang-cl.exe  - other profiles: asan
cache
  compiler caches  - sccache   not found (lw help cache)
                   - ccache    not found (lw help cache)
editor
  language servers  + clangd 18.1.8       C:\Program Files\LLVM\bin\clangd.exe
                    - qmlls               not found (install Qt's qmlls, or set type_config.qmlls)
  debug adapters    + codelldb 1.10.0     (Mason)
                    - cppdbg              not found (:MasonInstall cpptools)
launcher
  - launcher: lw 0.1.39 pinned; lw.sh / lw.cmd current, modes and line endings ok
submodules
  - submodules: 3 in sync with their recorded commits

14 other checks not relevant here (lw 5, toolchains 7, sdks 1, editor 1) - lw health --all

$ lw health --all
  (the same sections, each followed by what the workspace does not use:)
lw
  lw 0.1.39  C:\Users\me\.local\bin\lw.exe
  - update check skipped - offline or release server unreachable
  plugins  + 3 used here - not used here: + 5 loaded
toolchains
  ...the relevant lines above...
  not used here:
  build tools  - make - - meson - + node 20.11.1 - + npm 10.2.4
  compilers    + gcc 13.2.0 - + clang 18.1.8 - + MSVC 14.29 (VS 2019)
sdks
  not used here:
  SDKs  + HarmonyOS SDK 5.0.0
editor
  ...the relevant lines above...
  not used here:
  debug adapters  - js-debug

$ lw health toolchains
loomworks health - myapp  (C:\src\myapp)

toolchains
  build tools  + cmake 3.30.2             C:\Program Files\CMake\bin\cmake.exe  - dev (2 projects)
               + ninja 1.12.1             C:\tools\ninja.exe  - dev (2 projects)
  compilers    + MSVC 14.40 (VS 2022)     C:\Program Files\Microsoft Visual Studio\2022\Community  - dev (2 projects)
               + clang-cl 18.1.8          C:\Program Files\LLVM\bin\clang-cl.exe  - other profiles: asan

7 other checks not relevant here (toolchains 7) - lw health toolchains --all

$ cd C:\tmp
$ lw health
loomworks - no workspace here.

  lw init    start a workspace here

* Update available                                                  [lw]
  0.1.39 -> 0.1.40 on the stable channel
  lw self-update

lw
  lw 0.1.39  C:\Users\me\.local\bin\lw.exe

Machine inventory not checked outside a workspace - lw health --all lists
toolchains, compiler caches, SDKs and editor tools.
```

### 16.37 Release notes

*(Proposed.)* Every release carries its own **release notes** — a
human-written account of what changed, per version — and the runner shows
them **offline**, from the bundle it is running. They reach the user three
ways: on request (the release-notes command), right after an update
(self-update's "what's new" lines, §16.32), and once on the first interactive
run after an update the user was not told about (the **upgrade notice**).
None of these ever prompts, fetches anything, or changes an exit status.

**Source of truth.** The notes are one file at the root of the source tree,
`CHANGELOG.md`, newest first: an optional **Unreleased** entry, then one entry
per **full release**. A pre-release has no entry of its own: its changes are
the Unreleased entry of the tree it was cut from, and they become the next full
release's entry when that release is cut (*Release pipeline*, below). The file
is written for people — it renders as ordinary Markdown — but is held to a
strict grammar so that the runner, the release pipeline and the test suite read
it identically:

- anything before the first entry heading (title, introduction, comments) is
  preamble and is ignored;
- an entry starts at a level-2 heading: `## Unreleased` (at most one, and only
  as the first entry) or `## <version> - <YYYY-MM-DD>`, where `<version>` is a
  full release version (no pre-release suffix);
- an entry opens with a **summary** — one short paragraph saying what the
  release is about in a sentence or two (required for a released entry);
- then **sections**, each a level-3 heading from a fixed set, at most once per
  entry, in this order: `Breaking`, `Upgrade notes`, `Added`, `Changed`,
  `Fixed`, `Security`, `Removed`;
- a section holds **items**, each a `- ` bullet whose continuation lines are
  indented by two spaces. An item is one change, ending in the number of the
  change request that delivered it when there is one (`(#79)`);
- the text is ASCII only (host-level code prints it, §16.7), has no control
  characters, and uses Markdown only for `code spans`;
- released entries are in strictly descending version order; no version
  appears twice.

The test suite validates the file against this grammar, so a malformed entry
fails the change that introduces it, not the release. `Breaking` and
`Upgrade notes` are what a reader must act on; the short forms below surface
them, while the other sections appear in the full notes only.

**Baking.** The release bundle (§16.12) carries the notes file verbatim,
inside the bundle archive whose hash the signed manifest binds — so the notes a
user reads are exactly the signed release's, and showing them needs no network.
The notes are data of system Lua, never of the host: a host shows notes only by
reading them from a bundle (§16.32). The whole history is carried (tens of
kilobytes at most, compressed far smaller); nothing is truncated. A development
source (§16.11) reads the file from its working tree. A build that carries no
notes file (a development build with system Lua fused into the host) reports
that release notes are not available in this build, exit 1. The reader and the
renderer are pure functions over the file's text — no filesystem, process or
editor access — so one implementation serves the release-notes command, the
upgrade notice, and a host rendering a newly installed bundle's notes.

**Visible entries.** The version whose notes are current is the running
release bundle's version (the release source of §16.11; in pinned context, the
pinned release). A development source has none. The entries **visible** to a
run are:

- running a full release `R`: the released entries with version `<= R`;
- running a pre-release of `R` (e.g. `R-beta.2`): the released entries with
  version `<= R` (which may already include `R`'s own entry), preceded by a
  non-empty Unreleased entry presented under the running pre-release's version;
- a development source: every entry, a non-empty Unreleased entry first.

**Command.** `lw release-notes [<version> | --since <version> | --all | -n <N>]
[--json]` prints release notes. It needs no workspace and works outside one.

| Form | Shows |
|--|--|
| (none) | the three newest visible entries |
| `<version>` | exactly that entry (a leading `v` is accepted) |
| `--since <version>` | every visible entry newer than `<version>` — what changed after it |
| `--all` | every visible entry |
| `-n <N>` | the `N` newest visible entries (`N >= 1`) |

At most one selection form may be given; a second one, a malformed version, or
`N < 1` is a usage error (exit 2). A `<version>` without an entry is an error
(exit 1) that points at `--all`. `--since` a version at or above the newest
visible entry prints that nothing is newer, exit 0. The default is stateless —
the same output on every machine running the same release; "what changed since
I last looked" is the upgrade notice's job, and `--since` spells it
explicitly. When visible entries older than those shown exist, a last line says
how many and how to see them (`lw release-notes --all`).

Rendering follows §16.7: notes are printed as text, never as control
sequences. On a terminal they are wrapped to the terminal width (at most 100
columns) and use the runner's usual coloring; when standard output is not a
terminal nothing is wrapped, colored or cut — each item is one line, in full —
so the output can be piped or captured. `--json` prints one document instead:

```json
{
  "schema": 1,
  "running": "0.1.40",
  "entries": [
    {
      "version": "0.1.40",
      "date": "2026-09-30",
      "unreleased": false,
      "summary": "...",
      "sections": [ { "name": "Added", "items": ["...", "..."] } ]
    }
  ],
  "more": 11
}
```

`running` is null for a development source. An Unreleased entry has `version`
set to the running pre-release's version (null for a development source),
`date` null and `unreleased` true. `more` counts visible entries not shown.
An item's text is its lines joined by single spaces, Markdown as written.

The command documents itself (`lw help release-notes`, §16.7), follows the
unknown-option rule (§16.7), and its completion offers its options and the
versions the notes know.

**Last-seen version.** The runner remembers, per user, the newest release whose
notes the user has been pointed at — the **last-seen version**, kept in the
per-user data directory beside the installed bundles. It is only ever raised,
never lowered, and it is recorded when the release-notes command prints notes
as text, when self-update prints its "what's new" lines (§16.32), and when the
upgrade notice is shown. Failing to read or write it is silent.

**Upgrade notice.** A command run from an installed release bundle — acquired
by self-update or installation, not pinned (§16.21) — whose running version is
newer than the last-seen version prints **one line** to standard error before
the command's own output, then records the running version as seen:

```
lw: updated 0.1.39 -> 0.1.40 - see what's new: lw release-notes --since 0.1.39
```

The notice is shown only when standard error is a terminal and the run is
interactive (§16.3's non-interactive switches); a redirected, captured or
non-interactive run shows nothing and records nothing, so the notice waits for
the next interactive run. The release-notes command (which records instead),
help, completion, and the host commands never show it. It never changes the
command's output or exit status. With no last-seen version recorded yet (an
installation that predates the notice), the newest older installed bundle in
the data directory stands in for it; with neither, the running version is
recorded without a notice — a first installation has nothing to announce. A
pinned run never shows the notice: the pin chose that version, and pin
upgrades point at the notes themselves (§16.24).

The notice and self-update's "what's new" lines are silenced — nothing printed,
nothing recorded — by the `release-notes` setting set to `off`, or by the
`LOOMWORKS_RELEASE_NOTES` environment variable set to `off`, `0` or `false`
(which takes precedence over the setting). The release-notes command is never
silenced.

**Old hosts.** The command and the notice are system Lua and use no host (boot)
interface — the last-seen version lives at a path derived from the running
bundle's own location — so they work under every host the bundle supports
(§16.14). A host that predates this section prints no "what's new" lines after
its self-update; the upgrade notice on the next interactive run is how its
user learns what changed.

**Release pipeline.** Each change adds its items to the Unreleased entry.
Cutting a **full release** renames Unreleased to that release's heading
(`## <version> - <date>`), gives it its summary, and leaves an empty
`## Unreleased` above it. The release pipeline enforces this before anything
is published: a full-release tag whose version has no entry, whose entry lacks
a summary or items, or whose tree still has items under Unreleased, fails the
release with a message that names the file, what is missing, and the exact
heading to add. A **pre-release** tag needs no entry of its own; when its
Unreleased entry is empty the pipeline warns but does not fail. The release's
published description is generated from the same text: the release's entry for
a full release; for a pre-release, its Unreleased entry, or a line saying that
none was written.

**Modules and SDK providers.** These notes cover the core release only.
Separately distributed modules and SDK providers (§16.20) keep their own; the
grammar and reader are reusable for a per-module notes file, but the runner
does not show module notes yet.

### 16.38 Discoverability

Every **everyday** operation of the runner is discoverable from the runner's
own inline output — the status overview, usage errors, the line an operation
prints when it finishes, and empty listings — without first reading help.
Everyday means the path from an empty directory to a first build and its daily
use: initialising a workspace, adding a project, mapping a configuration set,
creating, selecting and removing a profile, building, running, testing,
cleaning, resetting, health, pulling and creating a worktree, publishing, and
describing an item. **Advanced** options (wrappers, machine-readable output,
transport timeouts, disambiguation flags, …) MAY be reachable only through
help. The rules:

- **The overview carries the index.** The status overview's command footer
  (§16.18) names the everyday commands; outside a workspace it points at the
  command index (§16.18).
- **Next step.** An operation that creates or initialises an item and leaves
  the user one step short of building ends by naming the next step's command:
  initialising a workspace names adding a project; adding a project or a
  configuration names mapping it into a configuration set and how to list the
  configurations to map; creating a configuration set names creating a profile
  from it; creating a profile names building it and making it the active
  profile (unless it was activated). Where an operand must be chosen from a
  listing (a toolchain, a configuration), the hint names the listing command.
- **Empty states.** An empty listing or an empty overview section names the
  command that fills it, as in the previous rule.
- **No dead ends.** A hint names only a command that acts on its subject as
  printed. A hint about a profile that is not the active one names that
  profile explicitly rather than an operand-less form that would act on the
  active one. After a profile is removed, its build directories are no longer
  any profile's; the hint names the reset that also covers such directories
  (§16.30) and says that it resets every profile.
- **Descriptions.** The single-profile view (§16.18) of a profile with no
  description offers the describe operation (§16.35) once, as a hint line.
- **Quiet where output is consumed.** Hints are secondary guidance, rendered
  as the overview renders its hints (dim on a terminal). They never appear in
  machine-readable output (`--json`, queries, `--print`), and the completion
  line of a build, test or run carries none — those are read by CI and scripts,
  and the overview's footer already names them.
- **The help index is complete.** The command index (`lw help`) lists every
  command (the host-level ones included) with every sub-command it accepts,
  and lists the topics that are not commands. Every option a command accepts is
  documented in that command's help topic, its short spelling included; only a
  pure alias of a documented command or sub-command, and an option accepted
  solely for compatibility as a no-op, MAY stay undocumented. A usage error that
  lists a command's sub-commands lists all of them.
