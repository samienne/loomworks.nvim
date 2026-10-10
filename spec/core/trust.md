> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 17. Workspace Trust

A workspace directory can come from anywhere — a clone, an archive, a copy from
another machine. Everything inside it is **untrusted input** until shown
otherwise. This section defines what loomworks will execute on the strength of
which file, in both hosts (editor and standalone CLI), and how a user
establishes trust in machine-local state. It complements invariant 17 (§15:
nothing runs from the current directory by accident): that invariant is about
*how* a named program is resolved; this section is about *who may name it*.

### 17.1 Trust classes

| Source | Class | May name programs, arguments, environment, working directories? |
|--|--|--|
| The project's own build description (the files a module's build system reads) | project | Yes — but only when the user **explicitly** configures, builds, cleans, tests or runs (§17.8) |
| `loomworks.json` (shared snapshot, §2.1) | shared | **Never** (§17.6) |
| `.nvim/loomworks.user.json` (working copy, §2.2) | local | Yes, when it carries a valid machine signature (§17.3) |
| `.nvim/loomworks.cache.json` (§2.3), `.nvim/loomworks.health.json` (§16.31) | local state | Read only when it carries a valid machine signature; never the source of an executable path (§17.7) |
| Tool / SDK detection on this machine (§3.3, §10) | machine | Yes |

Opening a workspace (loading it in the editor, `lw status`, completion, any
read-only command) must not execute anything named by shared or unsigned data.
Explicit operations may run the project's own build system (§17.8).

### 17.2 Machine key

On first use loomworks creates a **machine key**: 32 bytes from the host's
secure random source, stored as 64 hexadecimal characters in `trust.key` in the
**per-user data directory** — the same directory the standalone host uses for
releases (§16.11), so the editor and the CLI on one machine share one key. The
key is never stored in, or derived from, a workspace. It is created with
owner-only permissions where the platform has them (mode `0600`, in a `0700`
directory); on Windows the per-user local application-data directory is
already private to the user. An existing key is never overwritten; a malformed
key is an error that names the file (deleting it creates a new key — every
workspace's signed files then read as `invalid`, §17.4).

### 17.3 Signed files

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
deterministic sorted encoding of §2 — avoids any canonicalization ambiguity, and
the fixed first-line position cannot be confused with a nested member of the
same name. The workspace root is deliberately **not** bound: moving or renaming
the workspace directory, or seeding a git worktree from the main checkout on the
same machine (§16.25), keeps the files valid. Copying a working copy from
one workspace to another on the same machine is the same case: the copy is
**valid** there, and everything it names (profiles, toolchain selections,
launch configurations, environment) is used as from any signed working copy —
it was written by this machine's user, which is what the signature attests;
it does not attest which workspace it was written for. Both hosts produce identical
signatures for identical content. Readers remove the member before decoding, so
it never appears in loaded data; older loomworks versions read a signed file as
ordinary JSON.

A file is, on read:

- **valid** — the member is present and verifies under this machine's key;
- **unsigned** — no signature member (written by hand, or by a loomworks
  version before this section);
- **invalid** — a member is present but does not verify (copied from another
  machine, edited after it was written, or the key changed).

### 17.4 Handling unsigned and invalid files

| File | valid | unsigned | invalid |
|--|--|--|--|
| working copy | used | **refused** — review & trust, or discard | **refused** — review & trust, or discard |
| build cache | used | **ignored** — treated as absent; the next cache write replaces it | **refused** — reset offered |
| health cache | used | ignored (treated as absent), replaced by the next health run | ignored, replaced by the next health run |

- **Working copy refused.** The workspace does not load (the same posture as a
  version mismatch, §15 invariant 11): nothing in the file is read, and nothing
  overwrites it (the one exception is an explicit, confirmed configuration
  import, which replaces it unread after a backup, §16.39 and §17.5). The host
  offers two actions: **trust** — show a summary of what
  the file contains, with every program-bearing field (§17.6) listed — and,
  among the other contents, the `device` blocks' stage and archive sets
  (§18.9), since they choose what is copied to a device — and on
  confirmation re-sign it exactly as reviewed — or **discard** it (delete it;
  the workspace then loads from `loomworks.json` alone, §2.2). The message says
  whether the file is unsigned or modified outside loomworks. Because every
  loomworks write signs the file, a hand edit of the working copy therefore
  requires re-trust. A non-interactive host never trusts implicitly: trusting
  requires an explicit confirmation flag.
- **Build cache unsigned (migration).** A cache written by a loomworks version
  before this section carries no signature. It is **ignored**: not read, and
  the loaded workspace holds no build state from it (it is treated as empty in
  memory), with a one-line notice on each load that finds it. Loading never
  writes: the file is **replaced** by a freshly written, signed cache only when
  a command actually writes the build cache (a build, a configure, a clean,
  ...). Read-only commands (status, listing and showing items, export, health,
  help) and every preview or dry run leave it byte for byte. Its exact bytes
  are the disk baseline of the stale-save guard (§2.7), so that first write
  neither merges with it nor is refused. Nothing is lost that a build cannot recreate —
  units read as unconfigured and reconfigure into their existing build
  directories on the next build. Discarding is always safe (nothing in the
  file is used), so an attacker gains nothing by omitting the signature.
- **Build cache invalid.** The workspace does not load and the cache is not
  overwritten; the host offers the **reset** (nuke) of the build cache: the
  cache file, its backup, the health cache and the `.nvim/build/` tree are
  deleted under the deletion-safety rules (§15 invariant 3), then the
  workspace loads with no build state.
- **Health cache.** It records probe results only (no build state, nothing
  that drives execution by itself), so an unsigned or invalid one is simply
  ignored and replaced when next computed (§16.31).

**Migration decision.** On the first run after upgrading, every existing
workspace has an unsigned working copy and cache. The cache is ignored
(above) until the first cache write replaces it — it is regenerable, and
reading it cannot be made safe. The
working copy is the user's own configuration and cannot be regenerated, but it
also cannot be distinguished from a planted one; it is therefore refused with
the **trust** action, once per workspace. The review summary makes the one-time
confirmation meaningful: a planted file shows its program-bearing fields.

A file that changes on disk while the workspace is loaded is verified the same
way: an unsigned or invalid working copy, or an invalid cache, puts the
workspace back into the refused state rather than merging the change; an
unsigned cache change is ignored (the in-memory state is kept, and the next save
replaces the file).

A refused working copy that becomes valid on disk (restored, or re-signed by
`lw trust`) loads the workspace again. Likewise, the **trust** action on a
working copy that is already valid loads a workspace refused for trust.

### 17.5 Writers

Every writer of a signed file signs it: working-copy saves (every mutation),
cache saves, health-cache writes, workspace initialization, and a working-copy
pull between checkouts (§16.25). A pull reads its **source** working copy only
when that file is valid (a pull must not turn an untrusted file into a signed
one), and merges into a target working copy only when the target is valid or
absent. A configuration **import** (§16.39) is the one writer that signs
content from outside the working copy. It does so only as an explicit act of
trust, after the same program-settings review that trusting uses (§17.4) and a
confirmation (prompt or flag, never implicit). It writes into a target working
copy that is valid or absent, or replaces a refused one **unread** after keeping
a byte-exact backup: nothing of the refused file is read, kept or signed. Signing never fails a write: if the key is unavailable the file is
written unsigned (and will be refused or discarded on the next read, never
trusted), and the failure is reported.

### 17.6 Program-bearing fields

A **program-bearing field** names a program to run, adds arguments to a
program, sets the environment of a spawned process, names a spawned process's
working directory, or names a file-copy destination that is not statically
inside the workspace. Program-bearing fields are honored only from the signed
working copy (§17.4); in `loomworks.json` they are **ignored**. Core defines
the generic ones:

- a configuration's environment (`env`) and every compiler-family override's
  environment (`overrides.<family>.env`, §1.3.3);
- a launch configuration that sets a program, arguments, environment or
  working directory (§8.7) — the whole launch configuration is ignored, so a
  partially stripped launch never runs something other than what was written;
- a deploy destination (§8.8) that is not statically inside the workspace: any
  destination other than a relative path — optionally prefixed by the
  workspace-root built-in variable — with no other variable reference;
- a working-copy-only SDK installation path (§10.4) appearing in shared data;
- a `device` block's device-side environment (`env`) or working directory
  (`working_dir`) (§18.9; the project's block lives in its module section). Its `stage` / `archive` patterns are not
  program-bearing: they are statically confined to the build directory and
  select what an explicit remote run transfers, not what runs. A launch
  configuration's `device_log` options (§18.13) are not program-bearing either:
  they are opaque data a device runner validates and may never turn into a
  program, a path to execute, or device command text.

Modules add their own through the optional `trust_fields` declaration (§8.4):
the top-level `type_config` keys that are program-bearing (a language-server
binary override, a module's own environment block, language-server
arguments). Language-server option overrides (§2.2 `lsp`) exist only in the
working copy.

Ignored fields are removed from the shared layer **before** it is merged with
the working copy (§2.4), so they never enter the in-memory model and can never
be copied into the working copy by the implicit cascade, auto-sync, or a
revert (no laundering into signed state). They are not lost: when the user
publishes (§2.4, full or per-item), each ignored value is written back to the
shared snapshot at its original place, unless the working copy now supplies a
value there. Ignoring a field surfaces a **diagnostic** on the owning item,
naming the field and value, for as long as nothing in the working copy supplies
it — terse, pointing at the long explanation:

```
loomworks.json sets projects.App.launch.serve (command = node) — ignored: program settings are used only from your local config (lw help trust)
```

To use such a value, the user copies it into the working copy (an edit
command, or a hand edit followed by trust). Program-bearing fields do **not**
include selectors of machine-detected things (a profile's tool key, an SDK key,
a debug-adapter language) or the compiler-cache policy — whose launcher is
always one of the core-known launcher names, resolved from the search path
(§1.3.2); an unknown policy value names no program.

Descriptions (§1.10) are **not** program-bearing. They are display text that
is never expanded, executed or interpreted. They are therefore honoured from
loomworks.json, and a module's read-only default descriptions come from the
project's own files. Both are untrusted **display** input and are rendered
only under §17.11. The trust review (§17.4) does not list them.

A launch configuration's description is honoured from loomworks.json whenever
the launch itself is. A **target-backed** launch that names only a build target
(no `command`, `args`, `env` or `working_dir`) is not program-bearing. It is
used from loomworks.json, and so is its description. A launch that is ignored
as a whole because it is program-bearing (above) is not in the model, so its
description is not shown as a launch either. To help the user recognise the
launch, the diagnostic that reports it appends the description's **summary**,
rendered inert (§17.11):

```
loomworks.json sets projects.App.launch.schema-test (target = editor, args = --use-scene-json-schema …) "Editor with the scene JSON schema test data" — ignored: program settings are used only from your local config (lw help trust)
```

The description is written back at its place on publish with the rest of the
ignored launch.

### 17.7 Executable paths come from detection

Tool data recorded in the cache (§2.3) is a **record**, never a source of
executable paths — even in a valid cache (defense in depth). For a keyed tool,
the data used to run anything (compiler, build tool, developer-environment
script, language-server binary, tool environment) is the data **detection on
this machine** produced for that tool key; when cached and detected data differ,
detection wins. A tool key that detection did not produce is **not available**:
a profile using it is not buildable (§15 invariant 11, with the reason
"toolchain `<key>` is not detected on this machine"), and passive consumers
(language-server resolution) treat it as having no tool data. Tools derived
from a trusted SDK installation (§10) are detection results.

### 17.8 Passive and explicit execution

**Explicit** operations — configure, build, clean, test, run, debug — run the
project's own build system (the module's build tool resolved per §5.10, reading
the project's build description) even when nothing in the workspace is trusted
(a fresh clone with no working copy): that is what the user asked for, and the
project's build description can execute arbitrary code regardless of loomworks.
Build-description inputs a configuration carries (build options, toolchain or
cross files, a module's own build commands — see each module's spec) are part of
that description, not program-bearing fields.

**Passive** operations — anything that happens because a workspace was opened
or a file was viewed — run only what trusted state names:

- **Language servers** start only with a binary and arguments from the signed
  working copy, from detection (§17.7), or the integration's default resolved
  from the search path (§5.10). A compilation database is handed to a server
  only from a build directory recorded as configured in the signed cache — the
  same "configured on this machine" test as target scans below — so a database
  that came with the copy (or was left by an earlier, since-reset configure) is
  never read passively (§9.1, §9.8).
- **SDK validation** probes only installation paths from the signed working
  copy (§10.4).
- **Target scans and test discovery** (§8.4 `parse_targets`, §8.9) run only
  against build directories recorded as configured in the signed cache — i.e.
  configured on this machine; a build directory that merely exists on disk (it
  came with the copy) is never introspected and its binaries are never
  executed passively.
- **The editor's host binary** (§19.16): opening a workspace in daemon mode
  may download and run **official releases only** (the plugin-managed `lw`,
  verified against the hash the plugin pin carries, §19.16 "Plugin pin", or
  against a hash the plugin-pinned `lw` obtained from an official release's
  signed `SHA256SUMS`, §19.16 "Channel upgrades", §16.42); never a binary, a
  URL or a channel that a workspace file names. The channel and the release
  source come only from the editor's setup and the user's environment, and
  the channel query and the pre-launch probe (§19.16) never run with the
  workspace as working directory or with workspace-sourced environment.
- **Version-control queries** (§16.25–§16.27, status hints, the `lw health`
  submodule report §16.31) disable
  repository-configured command hooks (file-system monitor, hooks path) on
  every invocation and run the resolved absolute program (§5.10).

### 17.9 Environment denylist

Some environment variables make an unrelated program load or execute code:
dynamic-loader injection (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, any
`DYLD_*`), interpreter start-up hooks (`NODE_OPTIONS`, `npm_config_*`,
`PYTHONPATH`, `PYTHONHOME`, `PYTHONSTARTUP`, `BASH_ENV`, `ENV`), command
interpreter selection (`ComSpec`, `PATHEXT`), version-control command hooks
(`GIT_SSH_COMMAND`, `GIT_CONFIG_*`) and build-tool injection
(`CMAKE_TOOLCHAIN_FILE`, `CCACHE_PREFIX`). Names are matched
**case-insensitively** on every host (a prefix entry such as `DYLD_` matches
every name that starts with it). A configuration, module or tool environment
that sets one is **refused for that variable, always** — even from a trusted
working copy, because legitimate uses are rare and the effect is invisible: the
variable is dropped when the environment is composed, with a one-time warning
and a diagnostic on the configuration. Edit paths refuse to set one. `PATH`
stays allowed, with its existing warning (§1.3.3). The denylist applies to every
environment source loomworks composes — configuration, compiler-family
override, module environment block, tool environment and launch environment —
not to the user's own process environment. It also applies
to a declared device-side environment; a device program's loader search path
comes only from the staging manifest.

### 17.10 Hosts

- **Standalone CLI.** Any command that loads a refused workspace exits
  non-zero with a message naming the file, whether it is unsigned or modified,
  and the command to resolve it. `lw trust` prints the working copy's summary
  (program-bearing fields first) and asks for confirmation; `--yes` confirms
  non-interactively; `--discard` deletes the working copy instead. `lw nuke`
  resets an invalid build cache (with confirmation; `-y` skips it, and is
  mandatory in a non-interactive host — the reset posture of §16.30). Both
  hold the workspace operation lock while they remove files, and nuke also the
  build lock of every build directory it removes (§19.3): it refuses while a
  build runs instead of deleting under it.
  `lw help trust` explains this section.
  `lw status` (which a refused workspace never reaches) shows a `Trust` row:
  whether a working copy is present — then signed on this machine — or absent,
  and the number of program-bearing fields ignored in `loomworks.json` that
  the working copy does not supply (§17.6). It is the page's only statement of
  trust; the title is the workspace's name, which may be any word. A build
  whose profile's projects (or the workspace) have such ignored fields prints
  one notice line on standard error after naming the profile — the count, that
  only the local config may name programs or environment, and pointers to
  `lw status` and `lw help trust` — on the in-process and the daemon path
  alike (§19.15).
- **Editor.** The status page shows the refusal with the same actions (trust,
  discard, reset); a trust command shows the summary in a confirmation prompt.

Example messages:

```
lw: .nvim/loomworks.user.json was modified outside loomworks (its signature does not match this machine).
  Review and trust it:  lw trust
  Or discard it:        lw trust --discard

lw: .nvim/loomworks.cache.json was not written on this machine (its signature does not match).
  Reset the build cache (deletes .nvim/build and the cache): lw nuke
```

### 17.11 Display text from untrusted sources

Some workspace data exists only to be shown: descriptions (§1.10) and module
default descriptions taken from project files. Item names (project keys,
configuration and set names, profile keys) are displayed too. Such text can come
from a cloned repository, so every host renders it **inert**:

- **Never interpreted.** Display text is never expanded, evaluated, matched,
  or used as a format string, highlight or markup. It is inserted only as a
  literal value.
- **Terminal.** The rule of §16.7 applies: every control character except TAB
  and LF is rendered visibly (e.g. ESC as `^[`). Additionally, the Unicode
  bidirectional-override and isolate controls (U+202A–U+202E,
  U+2066–U+2069) are rendered visibly in description text (as `‮`), so a
  description cannot visually reorder the text around it. A one-line view
  shows the summary only, with each TAB rendered as a space. It never
  contains an LF, so a description cannot forge additional output rows.
  A multi-line view prints each line of the description separately, under
  the host's own indentation, so a description line can never look like
  the host's own output.
- **Editor buffers.** A buffer line never receives an embedded newline. A
  multi-line description becomes one buffer line per description line, or the
  summary alone in a one-line context. Control characters are rendered visibly,
  as in the terminal. Highlights come only from the host's own highlight
  ranges, never from the text.
- **Statusline, winbar and tabline.** Any such component that renders display
  text escapes `%` as `%%`, so the text cannot inject statusline items,
  highlight groups or expressions. It also removes control characters. This
  applies to item names as well as descriptions.
- **Notifications and pickers.** Only the summary is shown, with the same
  sanitisation as a buffer line.
