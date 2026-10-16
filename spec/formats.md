# Loomworks file formats

This document specifies the **files** a loomworks implementation reads and
writes that another implementation — a different program, or another version
of the same one — must be able to read, write or honour: the workspace
configuration, the working copy, the signature that guards machine-local
files, the lock files and the commit journal concurrent processes share, the
daemon handle, and the repository's version pin. It is meant to be enough to
read and write these files compatibly, but not more: it does not prescribe how
an implementation is built, and it does not repeat what the files *mean* to
the workspace model.

**Normative sources.** This document is normative for the **syntax** of these
files: their location, encoding, shape and field names, and the rules a
writer and a reader must follow to stay compatible. The **meaning** of the
data — intent and publishing, merging, reconciliation, trust, locking and
recovery — is the loomworks behavioural specification's; each section below
points to the sections that define it.

**Section numbers.** `§n` is a section of this document. `spec §n` is a
section of the loomworks behavioural specification
([specification.md](../specification.md) and its topic files under
[`spec/core/`](core/)). Text marked as moved comes from those sections,
which keep a pointer under the same heading or label; it stays normative as
written, including the parts of it that state meaning.

**Not covered.** The following are private to the implementation that writes
them, and a reader may discard them: the launcher scripts (`lw.sh`,
`lw.cmd` — their contract is behaviour, spec §16.22; their line endings and
executable bit are spec §16.21), the health cache
(`.nvim/loomworks.health.json`, spec §16.31), the runtime logs, `.nvim/tmp`,
`.nvim/cache/**`, the layout of `.nvim/build`, a build directory's
`.device-runs`, the per-user data directory (spec §16.40) apart from the
machine key (§2.1), and the device-side staging manifest (spec §18.4). The
export output (spec §16.39) is a `loomworks.json` (§3). The build cache is
described in §5 for information only.

## 1. Conventions

### 1.1 Files

| File | Path | Status | Section |
|--|--|--|--|
| Workspace configuration (published snapshot) | `<root>/loomworks.json` | normative | §3 |
| Working copy | `<root>/.nvim/loomworks.user.json` | normative | §4 |
| Build cache | `<root>/.nvim/loomworks.cache.json` | informative | §5 |
| Machine key | `trust.key` in the per-user data directory | normative | §2.1 |
| Lock files | see §6.2 | normative | §6 |
| Commit journal | `<root>/.nvim/loomworks.txn.json` | normative | §7 |
| Daemon handle | `<root>/.nvim/loomworks.daemon.json` | normative | §8 |
| Version pin | `lw.pin` at the repository root | normative | §9 |

`<root>` is the workspace root (spec §1.1).

### 1.2 JSON encoding

(Moved from spec §2. The three files are `loomworks.json`, the working copy and
the build cache.)

All three files are JSON written **deterministically**: object keys in sorted
order at every depth (arrays keep their order), so rewriting unchanged data
produces byte-identical output and an edit shows up as a minimal diff.

The export of spec §16.39 "Format" states this encoding as sorted keys,
two-space indentation and a trailing line feed, and writes a DEL or C1 control
character in a string as a JSON `\u` escape.

### 1.3 The `_meta` member

The working copy (§4) and the build cache (§5) carry a top-level `_meta`
object. `_meta.version` is the file's schema version; `loomworks.json` has no
version.
(Moved from spec §2.7 "Writer version stamp":)

**Writer version stamp.** Every write of the working copy and of the build
cache records, besides the schema version `_meta.version`, the writing
loomworks version as `_meta.written_by` (a development build records its last
released version with a `+dev` suffix; precedence ignores the suffix; a build
that cannot tell its version records none). In the
working copy `_meta` is part of the signed bytes (§2.2). Older versions read
only `_meta.version`, ignore unknown `_meta` members and rewrite `_meta`
without them; a file without `written_by` was written by such a version.

How a reader treats a file whose `_meta.version` is newer, the same with a
newer writer, or older than its own is spec §2.7 "Reading a newer file".

## 2. Machine key and signatures

### 2.1 Machine key

(Moved from spec §17.2.)

On first use loomworks creates a **machine key**: 32 bytes from the host's
secure random source, stored as 64 hexadecimal characters in `trust.key` in the
**per-user data directory** — the same directory the standalone host uses for
releases (spec §16.11), so the editor and the CLI on one machine share one key. The
key is never stored in, or derived from, a workspace. It is created with
owner-only permissions where the platform has them (mode `0600`, in a `0700`
directory); on Windows the per-user local application-data directory is
already private to the user. An existing key is never overwritten; a malformed
key is an error that names the file (deleting it creates a new key — every
workspace's signed files then read as `invalid`, spec §17.4).

### 2.2 Signature envelope

(Moved from spec §17.3. The health cache is not otherwise covered here.)

Every file loomworks writes under a workspace's `.nvim/` whose content can
cause execution — the working copy, the build cache and the health cache —
carries a signature. The signature is the **first member** of the file's
top-level object, alone on the file's second line, in exactly this form:

```
{
  "_sig": "<64 lowercase hex digits>",
  …rest of the file…
```

The **signed bytes** are the file with that member removed (`{`, a newline,
then everything after the member's line). The signature is

```
HMAC-SHA256(machine key, "loomworks-sig-v1\n" + kind + "\n" + SHA256-hex(signed bytes))
```

where `kind` is the file's role (`user`, `cache`, `health`), so a signed file of
one role cannot be renamed into another. Signing the exact bytes — which are the
deterministic sorted encoding of §1.2 — avoids any canonicalization ambiguity, and
the fixed first-line position cannot be confused with a nested member of the
same name. The workspace root is deliberately **not** bound: moving or renaming
the workspace directory, or seeding a git worktree from the main checkout on the
same machine (spec §16.25), keeps the files valid. Whether a working copy copied
from one workspace to another is valid there is spec §17.3. Both hosts produce identical
signatures for identical content. Readers remove the member before decoding, so
it never appears in loaded data; older loomworks versions read a signed file as
ordinary JSON.

How a reader classifies a file (valid, unsigned, invalid) and what it does
with each is spec §17.3–§17.4.

## 3. `loomworks.json`

The published snapshot. What it is for, when it is written and how it is
merged into the working copy are spec §2.1 and §2.4; which of its fields are
never trusted to name programs is spec §17.6.

### 3.1 Paths

(Moved from spec §2.1.)

- Paths are relative to workspace root.
- Absolute paths are **forbidden** (breaks portability).
- `${ENV_VAR}` expansion for toolchain paths.

### 3.2 Shape

(Moved from spec §1.9 "loomworks.json Schema".)

```json
{
  "name": "MyWorkspace",
  "projects": {
    "App": {
      "path": "packages/app",
      "cmake": {
        "configurations": {
          "Debug": {},
          "Release": {},
          "cross-debug": {
            "toolchain": "${VENDOR_SDK_ROOT}/cmake/cross.toolchain.cmake"
          }
        },
        "compile_commands_from": "ninja-debug",
        "clangd": "${VENDOR_SDK_ROOT}/llvm/bin/clangd"
      }
    },
    "Frontend": { "typescript": {} }
  },
  "configuration_sets": {
    "Debug":   { "App": "Debug",   "Frontend": "development" },
    "Release": { "App": "Release", "Frontend": "production"  }
  },
  "profiles": {
    "cross": {
      "configuration_set": "Debug",
      "kit_id": "ninja-cross-clang"
    }
  }
}
```

**Top-level fields**:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Workspace display name (defaults to root dir name). Published from the working copy's `name` (§4); the working copy wins at load |
| `projects` | Yes | Dict of project_key → project definition |
| `configuration_sets` | No | Dict of set_name → { project_key → variant } |
| `profiles` | No | Dict of profile_key → explicit profile definition |
| `configuration_set_descriptions` | No | Dict of set_name → description (spec §1.10). A sidecar because a set's own table is a flat project → configuration map with no room for a field |

**Project definition fields**:

| Field | Description |
|-------|-------------|
| `path` | Relative path from workspace root (defaults to project key) |
| `depends_on` | Reserved for future cross-project dependencies (ignored in v1) |
| `<type>` | Inner key determines project type; value is the type-specific config |

The type key (`cmake`, `meson`, `typescript`, etc.) is the only required field. Its
value is a table passed to the module as `type_config`.

The project's **description** (spec §1.10) is the core-owned key `description` inside
the module section (`projects.<key>.<type>.description`), not a project-level
key. Core lifts it out before the section reaches the module as `type_config`.
(An older loomworks reads an unknown project-level key as a second module type
and refuses the file; it keeps an unknown module-section field. This is the
same placement rule as the `device` block, spec §18.9.) The project-wide saved test
targets (`projects.<key>.<type>.tests`, spec §1.3.4) are another such core-owned
key in the module section.

**CMake type_config fields**:

| Field | Description |
|-------|-------------|
| `configurations` | Dict of config_name → config overrides |
| `compile_commands_from` | Name of another configuration to source compile_commands.json from |
| `clangd` | Path to project-specific clangd binary (`${ENV_VAR}` expanded) |

Configuration overrides may include:
- `toolchain`: path to CMake toolchain file (`${ENV_VAR}` expanded, no absolute paths)
- `role`: `"compile_commands"` hides the configuration from UI
- `description`: the configuration's description (spec §1.10), valid in every module's
  configuration table; a generic field, not a module field
- `tests`: the configuration's saved test targets (spec §1.3.4); a generic field,
  not a module field

**Explicit profile fields**:

| Field | Description |
|-------|-------------|
| `configuration_set` | Name of a configuration set to derive mappings from |
| `kit_id` | Tool key to use (e.g., `"ninja-clang-18.0.0"`) |
| `description` | The profile's description (spec §1.10) |
| `default_target` | The profile's default target (§3.4) |

### 3.3 Descriptions

The meaning of descriptions, their display and how they follow renames are
spec §1.10. (Moved from spec §1.10 "Location in the files" and "Shape":)

**Location in the files.** The same locations apply in loomworks.json and in
user.json:

| Item | Location |
|--|--|
| Project | `projects.<key>.<type>.description` (inside the module section, §3.2) |
| Configuration | `projects.<key>.<type>.configurations.<name>.description` |
| Configuration set | `configuration_set_descriptions.<set_name>` (top-level sidecar, §3.2) |
| Profile | `profiles.<key>.description` |
| Launch configuration | `projects.<key>.launch.<name>.description` (inside the launch configuration's own table, spec §8.7) |

The field is additive and optional. Absence means "no description", and there
is no format-version bump. The loomworks.json file has no version, user.json
stays at `_meta.version` 2, and the cache is unaffected. A sidecar entry naming
no configuration set is ignored, and the next write of that file drops it.

**Shape.** A description is a JSON string. It is stored **normalised**:

1. Line endings are LF. CRLF and lone CR become LF.
2. Trailing whitespace is removed from every line.
3. Leading and trailing blank lines are removed.
4. A description that is then empty is **absent**. The key is removed from the
   file and never stored as `""`.

### 3.4 Fields defined elsewhere

The following members are defined, with their shape, in the sections named.
The same members appear in the working copy (§4).

| Member | Section |
|--|--|
| `projects.<key>.variables` (declarations), `projects.<key>.<type>.configurations.<name>.variables` and `.overrides` | spec §1.3.1 |
| The reserved `cache` variable | spec §1.3.2 |
| `env` (in a configuration and in a compiler-family `overrides` block) | spec §1.3.3 |
| `projects.<key>.<type>.tests`, `projects.<key>.<type>.configurations.<name>.tests` | spec §1.3.4 |
| Configuration inheritance (`inherits`) and module options | spec §1.3, the module's file under [`spec/modules/`](modules/) |
| `projects.<key>.launch.<name>` (launch configurations, `deploy`) | spec §8.7 |
| `projects.<key>.<type>.device` | spec §18.9 |
| `profiles.<key>.default_target` (`{ project, target, working_dir? }`) and the working copy's `default_target` map keyed by profile key (§4) | spec §8.6 "Default target storage" |
| The rest of `projects.<key>.<type>` (the module's `type_config`) | the module's file under [`spec/modules/`](modules/) |

## 4. `.nvim/loomworks.user.json`

The working copy. Its role, the files it must stay self-contained against and
when it is written are spec §2.2; intent and publishing are spec §2.4; the
guards against concurrent writers are spec §2.7. It carries `_meta` (§1.3)
and is signed with the `kind` `user` (§2.2). It shares the project,
configuration-set, profile and description shapes of `loomworks.json` (§3).
(Moved from spec §2.2:)

```json
{
  "_meta": { "version": 2, "written_by": "0.1.43" },
  "name": "reactive",
  "active_profile": "Debug:ninja-gcc-12",
  "projects": { ... },
  "configuration_sets": { ... },
  "configuration_set_descriptions": { ... },
  "profiles": { ... },
  "intent": { ... },
  "default_target": { ... },
  "device": { ... },
  "profile_variables": { ... },
  "lsp": { ... }
}
```

The `device` field maps profile keys to device serial strings:
```json
"device": {
    "Debug:<sdk>-<platform>-<arch>": "FMR0225108000951"
}
```
It is unrelated to a project's `device` block (`projects.<p>.<type>.device`,
spec §18.9), which shapes remote execution and lives in the project definition.

The `profile_variables` field holds each profile's machine-local fill values
for **blank** project variables (spec §1.3.1), keyed profile → project → variable:
```json
"profile_variables": {
    "Debug:ninja-gcc-12": {
        "App": { "sdk_root": "/opt/sdk/3.2" }
    }
}
```
Whether the field is published, and how the values it holds merge, is
spec §2.2 "`profile_variables`".

The optional `name` field overrides the workspace display name (spec §1.1).
When it is present, its default and how it is published are spec §2.2
"`name`".

The `intent` field stores explicit per-item intent overrides (see spec §2.4).

The `default_target` field maps profile keys to a default target (§3.4).

The `configuration_set_descriptions` field holds configuration-set descriptions
(spec §1.10), keyed by set name. It has the same shape and meaning as in
loomworks.json. A set's entry lives in whichever files the set itself lives in.
Descriptions of projects, configurations and profiles sit inside those items'
own tables (spec §1.10).

The `lsp` field stores per-server option overrides. Keys are server
names (e.g. `clangd`); values are option tables whose accepted shape
is defined by the integration's spec under `spec/integrations/lsp/`.
All fields within a server table are optional — omitted fields fall
back to the integration's hardcoded defaults. It is a top-level
field of the working copy, not a project member; when it is saved
and what it applies to are spec §2.2 "`lsp`". See `spec/integrations/lsp/clangd.md` §12 for clangd's
specific schema and how options map to cmd flags.

## 5. `.nvim/loomworks.cache.json` (informative)

The build cache is private to the implementation that writes it. Its shape
and field meanings are described in spec §2.3, and an implementation that
wants to share build state with another implementation follows that section.
It carries `_meta` (§1.3) and is signed with the `kind` `cache` (§2.2). A
cache a reader cannot use is handled by the rules of the behavioural
specification: unsigned, spec §17.4 "Build cache unsigned (migration)";
invalid, spec §17.4 "Build cache invalid"; a newer or older schema, spec §2.7
"Reading a newer file". How concurrent writers merge it is spec §2.7 "Build
cache: merge".

## 6. Lock files

### 6.1 Common lock record

(Moved from spec §19.5 "Lock record".) What a lock means, how a holder is
classified (dead, live, hung, stale foreign) and how a lock is recovered are
spec §19.5.

**Lock record.** Every lock record carries: process id, host name, the
holder's **process start time** (as reported by the operating system; it
distinguishes a reused process id), a random nonce, the holder kind (`lw`,
`daemon`, or `editor`), the operation, and a start timestamp; its modification
time is the heartbeat. As JSON: `{ pid, host, start_time, lock_nonce, kind,
operation, started_at }`, plus `action` (a copy of `operation` that older
versions read) and the class's own fields. The nonce is `lock_nonce`, not
`nonce`: device-lock records already use `nonce` for their running program
(spec §18.7). `start_time` is opaque and carries its method (`win:`, `linux:`,
`mac:`); a value written by a method the reader cannot use is judged by
heartbeat alone. It is a string, compared only for equality: `win:<creation
time>` (the process creation time in 100 ns units, decimal),
`linux:<boot id>:<start ticks>` (field 22 of `/proc/<pid>/stat`, with the
boot id) or `mac:<seconds>.<microseconds>` — so it may itself contain colons,
and a daemon's handle carries the same value as its runtime-lock record
(§8). A daemon **instance id** `<pid>:<start_time>` (spec §19.10 "Skip an
instance") is the decimal pid, a colon and that value verbatim; it is split
at its first colon. A holder that holds a build-directory lock across
several steps rewrites the record's operation when it moves from configure to
build, so recovery knows which step was interrupted. A record without a start time (written by an older
version) is judged by heartbeat alone. A lock file is created with its
record already in it: the record is written to a temporary file beside it
(`<lock file>.new.<nonce>`, a name no lock-file reader or scan matches) and
given the lock file's name by a hard link, an atomic create-if-absent; the
temporary name is then removed. Where the file system has no hard links, the
lock file is created exclusively and its record written right after. A
holder rewriting its record writes a temporary file and renames it over the
lock file; that the lock file still carries its nonce is checked right
before each rename, so a narrow window remains in which a lock file forced
off or reclaimed between the check and the rename is overwritten (no wider
than with the earlier in-place rewrite). A reader that
finds a fresh empty lock file (modified within the last 2 s; one created
without hard links, or by an older version) reads it again for up to 250 ms
before judging it, so a record being written is never taken for another
host's live holder; one still empty then is judged as a record without fields.

### 6.2 The lock files

| Lock | File | Record | Section |
|--|--|--|--|
| Runtime (R) | `<root>/.nvim/loomworks.daemon.lock` | the common record (§6.1) plus the runtime's fields below | spec §19.2 |
| Workspace operation (O) | `<root>/.nvim/loomworks.op.lock` | the common record | spec §19.3 |
| Build directory (B) | `<build dir>.loomworks-lock` | the common record | spec §16.6 |
| Device (D) | `<data>/device-locks/<serial>.lock`, with `<data>/device-locks/<serial>.leftover` for a program left running (spec §16.40); `LOOMWORKS_DEVICE_LOCK_DIR` relocates the directory (spec §16.34) | the common record plus the device fields of spec §18.7 "Leftover programs" | spec §18.7 |
| File save (F) | `<file>.lock` beside the guarded file | the common record | spec §2.7 "Write lock" |

(Moved from spec §19.2.) The runtime lock's record is the common lock record of
§6.1 plus the mode (`daemon` or `attached`), for an attached run the command,
and the host version.

## 7. Commit journal `.nvim/loomworks.txn.json`

The commit and recovery procedure, and what happens to a journal that cannot
be completed, are spec §19.4. (Moved from spec §19.4:)

The journal is a JSON object `{ id, operation, pid, host, written_by,
entries: [ { file, action = replace|remove, sha256_new?, sha256_old? } ] }`,
its entries in the file order of spec §19.3.

**Validation.** A journal is data from disk: it is honoured only when every
entry names one of the three workspace files in `.nvim/` and the staged files
match `<file>.txn-<hex id>` beside them; anything else refuses the workspace
(spec §19.4 "Recovery"). How the files it rolls forward are then verified
is spec §19.4 "Validation".

## 8. Daemon handle `.nvim/loomworks.daemon.json`

When the handle is written, refreshed and rewritten, and how it is used for
discovery, are spec §19.6; the daemon key *K* is spec §19.8. (Moved from spec
§19.6:)

A daemon publishes `<root>/.nvim/loomworks.daemon.json` after binding its
endpoint: `{ pid, host, os, start_time, endpoint, protocol, lw_version,
schemas = { user, cache }, session_generation, started_at, clients, busy,
idle_since, lock_nonce, key_id, exe }` (`start_time` is the daemon's process start time of
§6.1, `lock_nonce` its runtime-lock record's nonce, `exe` the path of the
executable it runs — for display only, such as the editor's version-mismatch
note, spec §19.16; never executed or trusted for a decision). `key_id` is a
non-secret fingerprint of the daemon key K it authenticates with (spec §19.8): the
first 16 hex digits of HMAC-SHA256(K, `"loomworks-daemon-key-id-v1"`). It
tells, without connecting, whether a daemon belongs to this lw's data
directory (machine key) — a daemon of another `LOOMWORKS_DATA_DIR`, such as a
test run's, has another key and could never complete the handshake with this
lw. It is one-way under its own label and is never part of a proof. A
development build's
`lw_version` is its source fingerprint (spec §19.9).

## 9. `lw.pin`

When a repository carries a pin, how a launcher or a host reads and verifies
it, and the line endings it is committed with are spec §16.21–§16.24. (Moved
from spec §16.21:)

The pin declares a release **version** and, for every host binary and for the
release bundle, the **content hash** of that artifact. It is a trivially
parseable key/value list (not JSON) so a launcher can read it with a system
shell alone — one `version` entry, one hashed entry per host binary keyed by the
binary's asset identity, and one hashed entry for the bundle. The pin carries a
version and hashes **only, never a location**: the download origin is fixed by
the host and overridable solely by the user's environment or host configuration,
never by repository content (spec §16.23).

## 10. Earlier writers

Files written by earlier loomworks versions are covered where each format is:

- lock records without a start time: §6.1;
- working copies and build caches without `_meta.written_by`: §1.3;
- unsigned working copies and build caches: spec §17.3–§17.4;
- build-directory lockfiles (moved from spec §16.6): a version before the
  identity rule of spec §16.6 derives the lockfile from the spelled path, so with
  an aliased spelling (a symlinked or junctioned workspace root, macOS `/tmp` →
  `/private/tmp`) an older pinned `lw` and a current one take different
  lockfiles and do not exclude each other.
