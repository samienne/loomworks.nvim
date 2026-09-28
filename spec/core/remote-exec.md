> Part of the loomworks core specification -- see [`../../specification.md`](../../specification.md) for the index and the section-range routing table.
> The section numbers below are the ORIGINAL global numbers from the core spec; they are NOT local to this file and do NOT restart at 1.

## 18. Remote Execution on Devices

A build made with a cross-compiling kit produces programs the host cannot run.
This section defines how such a program — a **plain process**: an executable
plus the files it needs beside it, not an installable application package — is
run on a connected device instead: which builds are foreign, who supplies the
means to reach a device, what is transferred, how the program is executed and
its exit status recovered, how its output and the device's logs come back, and
how test results and crash evidence are collected.

It complements the module device interface (§11), which installs and launches
**application packages** through the module that builds them. The two coexist:
§11 is for artifacts only a module understands (a package with a manifest and
an entry point); §18 is for the ordinary executables any module builds, and is
supplied by the **SDK provider** whose kit produced them (§10). The connector to
a device belongs to the platform installation, not to a build system: every
module building for the platform needs the same connector, and only the SDK
knows where it is. No build module therefore needs to know how to reach a
device.

### 18.1 Execution platform

Every Tool (§1.5) has an **execution platform**: `nil` for a tool whose output
runs on the host, or an opaque **target-platform token** for a tool whose output
runs elsewhere. The token is set by whoever produces the tool — for an
SDK-derived kit, the SDK provider declares it in its capability data and the
module copies it onto the kit (§10.7). Host-detected tools never carry one.
Tokens are free-form and provider-defined; core compares them only for equality
(a kit's token against the `platforms` of the runner of the SDK that produced
the kit) and never parses them.

A build-target artifact is **foreign** when either:

1. the Tool that built its ConfigUnit has a target-platform token; or
2. the **host-executability probe** fails: before core executes a build-target
   artifact locally, it reads the artifact's executable-format header and
   compares the format — and, where the format records one, the machine
   architecture — with the host's. A mismatch makes the artifact foreign. The
   probe catches cross builds the tool does not know about (a toolchain file set
   by a configuration or preset rather than by a kit). An unreadable or unknown
   format is not a mismatch (the probe never refuses what it cannot judge).

**Invariant: a foreign artifact never executes on the host.** Every local
execution path for a build-target artifact — launch (§8.7), headless run
(§16.17), the run environment of a target-backed launch configuration, test
discovery probes (§8.9) — checks this first. A foreign artifact is either
**routed to a device** (§18.5) when a device runner serves its platform (§18.2)
and the operation supports remote execution, or **refused** with a message
naming the artifact, the platform, and the remedy:

```
lw: LumeSceneAPITestRunner was built for ohos-aarch64 by kit ohos-openharmony-arm64-v8a;
    this host cannot run it. No device runner serves that platform.
```

Command-type launches (§8.7) are not probed: their command is the user's own
program (possibly an emulator or a wrapper that handles foreign binaries).
A probe-detected mismatch with no tool token has no platform to route by, so it
is **refused**, never guessed onto some device — even when exactly one runner
is in scope.

### 18.2 Device runner contract

An SDK provider MAY supply a **device runner** for the platforms its kits
target, through the optional provider hook:

| Hook | Purpose |
|------|---------|
| `device_runner(sdk) → Runner\|nil` | The runner for this installation, or `nil` when the installation has no usable device connector |

A Runner is a table of **command-spec builders and output parsers**. It never
spawns a process itself: core executes every spec, so process spawning,
timeouts (§18.8), cancellation, output normalization and locking are owned by
core and uniform across runners and hosts. A spec is
`{ cmd, args, env?, check_output? }` as in §11.2; `cmd` MUST be a path derived
from the SDK installation (§17.7) — never a program found on the search path —
and `args` is an argument vector that core passes without any host command
interpreter.

**Identity and capabilities:**

| Field | Type | Purpose |
|-------|------|---------|
| `id` | string | Runner identity (normally the provider id); becomes `Device.provider` |
| `platforms` | string[] | Target-platform tokens this runner can execute |
| `staging_base` | string | Absolute device-side directory under which core stages files (§18.4) |
| `archive` | boolean | The device can unpack a single uncompressed archive in the portable tape-archive format (§18.4) |
| `digest` | string[]\|nil | Device-side argv prefix that prints `<hex digest>  <path>` per file argument; `nil` = no remote verification |
| `combined_output` | boolean\|nil | The connector delivers the program's standard error merged into its standard output (§18.13) |
| `timeouts` | `{ query?, transfer? }`\|nil | Overrides of the default transport timeouts, in seconds (§18.8) |

**Builders** (all required unless marked optional):

| Builder | Returns | Notes |
|---------|---------|-------|
| `list_devices()` | spec | Enumerate attached devices |
| `parse_devices(lines)` | `{ serial, display_name, state, properties }[]` | Placeholder lines (e.g. an "empty" marker) are not devices |
| `push(serial, local, remote)` | spec | One file host → device. `local` is an absolute host path; the runner renders it in whatever form the connector requires |
| `pull(serial, remote, local)` | spec | One file device → host |
| `exec(serial, request)` | spec | Run one program on the device (below) |
| `parse_exit(line, nonce)` | `integer\|nil` | Recognise the exit-status sentinel line for `nonce` |
| `parse_pid(line, nonce)` | `integer\|nil` | *(optional)* Recognise the line announcing the device-side process id of the program started with `nonce` |
| `terminate(serial, nonce, pid?)` | spec | *(optional)* Stop the device-side program started by `exec` with `nonce` (`pid` when `parse_pid` reported one) |
| `crash_snapshot(serial)` | spec, `parse(lines) → set` | *(optional)* Identify the device's current crash reports |
| `crash_collect(before, after)` | remote path[] | *(optional)* Crash reports new since the snapshot |
| `runtime_files(tool)` | `{ local, relative }[]` | *(optional)* Platform runtime files a program built by `tool` needs beside it (§18.4) |
| `log_session(serial, options, program)` | `Session\|nil, err` | *(optional)* The runner log stream for one run (§18.13) |

**`exec` request.** `{ argv, cwd, env, library_dirs, nonce }` — `argv[1]` is a
device-side path, `cwd` and every `library_dirs` entry are device-side
absolute paths, `env` is a name → value map, `nonce` is an unpredictable token
core generates per execution. The rendered command MUST:

- deliver every `argv` element to the program as **exactly one argument,
  byte-for-byte**, and every `env` value verbatim — the runner quotes for the
  device's command language; nothing in a request can add a command;
- make `library_dirs` searchable by the device's dynamic loader, by the
  platform's own mechanism (the loader-path variable is the runner's business,
  not the caller's);
- run the program with `cwd` as its working directory;
- when the runner offers `parse_pid`, emit the process-id line for `nonce`
  before the program produces any output;
- after the program exits, emit one line that `parse_exit` recognises for this
  `nonce` and that carries the program's exit status, so the status is
  recovered even when the connector does not propagate it. A line that merely
  resembles a sentinel without the nonce is program output.

Sentinel and process-id lines are connector lines: core consumes them and never
shows or saves them as program output.

Core refuses a request — before building any spec — when an `env` name is not a
portable identifier (`[A-Za-z_][A-Za-z0-9_]*`), or any `argv`, `env`, `cwd` or
path element contains a NUL or a line break.

`check_output` (§11.2) on `push`, `pull` and `exec` detects connector-level
failures reported in output with a success status (a transfer the connector
rejected, a device that vanished). On `exec` it inspects only lines the
connector itself emits before the program starts or after the sentinel —
never program output.

### 18.3 Device selection

Devices listed by a runner join the workspace device registry (§1.8) with
`provider` = the runner id. Identity is the serial; a serial reported by both a
module (§11) and a runner is one Device.

The device for an operation is resolved in this order, first match wins:

1. an **explicit** selection for this operation (a command-line option, or the
   editor's picker);
2. the profile's **persisted** device serial (§1.8);
3. the **sole online** device the runner lists.

A persisted or explicit serial that the runner does not list online is an
error naming it — core never substitutes another device. No device, or more
than one with nothing selected, is an error listing what was found. A
non-interactive host never prompts; the editor prompts on ambiguity and
persists the choice to the profile. An explicit command-line selection applies
to that invocation only; persisting is a separate management operation (§16.34).

### 18.4 Deploy manifest and staging

Before executing, core **stages** the program on the device. The staging root on
the host is the ConfigUnit's build directory; the device-side root is

```
<staging_base>/<workspace name>/<config unit identity>/
```

and every staged file keeps its **build-directory-relative path** below it, so
relative references between build outputs (a program that loads
`plugins/*.so` beside itself or reads `../../assets`) resolve on the device
exactly as in the build tree.

The **manifest** is the union of:

1. **The artifact** — the program itself (marked executable on the device).
2. **Derived runtime libraries** — the shared- and module-library artifacts of
   project build targets the artifact's target depends on, transitively, as the
   module reports them (§8.4 `parse_targets` dependencies, `resolve_artifacts`).
   Nothing is guessed: a module that reports no dependencies contributes none.
3. **Platform runtime files** — `runtime_files(tool)` from the runner (e.g. the
   shared language runtime a kit links against), staged beside the artifact.
4. **Declared stage sets** — the `device` block's `stage` patterns (§18.9),
   each a glob relative to the build directory, mirrored with layout preserved.
5. **Declared archive sets** — the `device` block's `archive` patterns: staged
   like (4) but, when the runner supports archives, transferred as **one**
   archive and unpacked on the device (large or deeply nested data trees).
   Without archive support they are staged file by file.

Patterns are relative, may not be absolute, and are matched against the
build-directory-relative path after normalization; a pattern whose fixed prefix
escapes the build directory (`..`) is refused. Every file in the manifest must
exist when staging starts; a derived file that is missing is an error naming it.

**Incremental sync.** Core records, per device serial and staging root, the
size and content digest of every file it has staged, in the build cache
(§2.3, runtime state — never shared). A file is transferred only when it is
new or its digest changed; an archive set is re-sent when the digest of its
member list changes. When the runner declares `digest`, core verifies recorded
files against the device before trusting the record (a device that was wiped
or re-flashed is re-staged); without it, the record is trusted and a
`fresh` request (§16.34) forces a full re-stage. Files removed from the manifest
are removed from the device staging root.

Deploy steps (§8.8) run on the host before staging, unchanged — a file they
place inside the build directory is staged if the manifest selects it.

### 18.5 Remote execution

A remote run holds the device lock (§18.7) for its whole duration and performs:

1. **Log session** — when the runner offers `log_session`, core opens it with
   the run's log options (§18.13); invalid options fail the run here, before
   any device-side effect.
2. **Stage** (§18.4).
3. **Prepare** — the log session's `clear` step, if any (best-effort), then
   the crash snapshot when the runner offers one.
4. **Execute** — `exec` with `argv` = the staged artifact plus the forwarded
   arguments, `cwd` = the artifact's device-side directory unless a working
   directory is declared, `library_dirs` = the device-side directories of every
   staged shared library (sorted, deterministic), `env` = the declared device
   environment. Program output streams live (§18.13); core normalizes line
   endings to LF. When `parse_pid` reports the program's process id, core
   starts the session's log stream (§18.13).
5. **Exit status** — the sentinel's status is authoritative and is the run's
   exit status. A status above 128 is additionally reported as "terminated by
   signal N". If the transport ends without a sentinel, the run failed to
   report a status: that is a device/transport failure, reported as such
   (never as the program's exit 0 or 127). After the sentinel, the log stream
   is drained briefly and stopped.
6. **Collect** — pull declared result files (§18.6), then crash reports new
   since the snapshot, into the **run folder**
   `<build dir>/.device-runs/<UTC timestamp>-<serial>/`, beside the saved
   program output and runner log (§18.13). The folder is reported whenever it
   holds anything beyond the program output, and always on failure. Core keeps
   the **10 newest** run folders per ConfigUnit and prunes older ones.
7. **Crash report** — each collected crash report is named in the summary; a
   crash makes the run fail even if the program's status says otherwise.

Standard input is not forwarded to the device program.

### 18.6 Remote tests

A test executable (a build target run by the test runner) that is foreign runs
on a device through §18.5, with the framework's machine-readable results option
pointed at a device-side file in the staging root; the file is pulled to the run
folder and parsed with the same parser as local results (§8.9). The outcome is
**failed** when any of: the exit status is non-zero; the parsed results contain
a failure or error; results were requested but no results file came back; a
crash report was collected. Framework detection (§8.9 list probe) runs through
the runner like any other execution.

Which tests run on a device in this version: the test executables named
explicitly in a headless test invocation (§16.16). Tests registered with a
module's native batch runner are not run on a device in this version. The
planned route (later): the module lists its registered tests **statically** —
without executing anything on the host — as program + arguments + working
directory + environment, and core turns each into an exec request with host
build-directory paths translated to staged device paths, so the batch runner
itself (a host program) is never asked to execute foreign binaries.

### 18.7 Device lock

One remote operation at a time per device per host. Core takes an exclusive
**per-serial lockfile** in a per-user state directory (the same atomic-create +
heartbeat mechanism as build-directory locks, §16.6), shared by the editor, the
CLI and every workspace on the host. Unlike a build-directory lock, a device
lock **waits** by default (queueing for a shared device is normal), printing the
holder once; a host option fails fast instead. The wait has no deadline; the
operations performed under the lock do (§18.8). A stale lock (heartbeat lapsed)
is reclaimed.

The lock directory can be relocated with the host environment variable
`LOOMWORKS_DEVICE_LOCK_DIR`, so that loomworks processes on one host — or a
device farm that serialises on `<dir>/<serial>.lock` — share one lock
directory. Interoperating with a particular farm's own lock-file format is
validated when such a farm is integrated; until then the override only
relocates loomworks' own lockfiles.

### 18.8 Timeouts, liveness and cancellation

Device connectors can block forever when a device disappears mid-operation.
Every transport spec core executes has a **hard timeout**, after which the
host-side process is killed and the operation fails naming the step. The
defaults are **query** (listing and short device commands) 120 s and
**transfer** (each file transfer) 600 s; a runner MAY override either through
its `timeouts` field, and a host MAY override either per invocation (§16.34),
the invocation winning. The program execution itself has **no** default timeout
(it is the user's program) but is watched for **liveness**: while it runs, core
re-lists devices periodically; the device missing from two consecutive listings
ends the run as a transport failure. A caller MAY set an execution timeout. The
runner log stream (§18.13) has no timeout of its own: it lives exactly as long
as the run.

Cancelling a remote run (interrupt in the CLI, stop in the editor) kills the
host-side transport process, then runs `terminate` when the runner offers it, so
the device-side program does not outlive the run, and stops the log stream.
Staged files are kept.

### 18.9 The `device` block

A project MAY declare, and a launch configuration MAY override, a `device`
block that shapes remote execution of its build targets:

```json
"device": {
    "stage":   [ "test/unittest/api_unit_test/**" ],
    "archive": [ "test/assets/**" ],
    "env":     { "SCENE_LOG_LEVEL": "debug" },
    "working_dir": "test/unittest/api_unit_test"
}
```

| Field | Meaning | Trust (§17.6) |
|-------|---------|---------------|
| `stage` | Globs relative to the build directory, staged file by file | honored from shared config (statically inside the build directory) |
| `archive` | Globs relative to the build directory, staged as one archive | honored from shared config |
| `env` | Device-side environment for the program | program-bearing: working copy only |
| `working_dir` | Build-directory-relative working directory on the device | program-bearing: working copy only |

A launch-level block replaces the project-level block field by field. A
declared device environment is subject to the environment denylist (§17.9)
like any other environment source; the loader search path is supplied only by
the manifest (`library_dirs`, §18.5).

### 18.10 Relation to the module device interface

A module implementing §11 MAY obtain its devices and transport from the device
runner of its profile's SDK instead of running the connector itself; its
package install/launch/log specs stay module-owned. Device listing is then
single-sourced, and a device picked for a package launch is the same Device a
remote run uses.

### 18.11 Remote execution in the editor

Launching a foreign module target from the editor follows §18.5 instead of a
local launch: the launch chain becomes build → deploy → stage → execute, program
output streams into the launch output view, the runner log stream (when shown,
§18.13) into the device log view (§11.3), stop cancels (§18.8), and the run
folder is announced on completion. Debugging a foreign target is refused in
this version. Test-explorer integration for remote tests is deferred.

### 18.12 Remote deletion safety

Core only ever asks a device to remove paths under
`<staging_base>/<workspace name>/`, checked with a separator boundary
(`path == prefix` or `path` starts with `prefix .. "/"`) after normalization,
never a path assembled from unchecked cache content.

### 18.13 Program output and the runner log stream

A remote run produces at most **two** output streams. Core knows nothing about
either beyond what is stated here: it never parses, levels, tags or filters
device logs; everything platform-specific about logging belongs to the runner.

**1. Program output** — what the program writes to its standard output and
standard error, as the connector delivers it. When the runner declares
`combined_output`, standard error arrives merged into standard output and core
treats the program output as **one** stream (it does not claim to tell the two
apart); otherwise core keeps them apart for display. Program output is always
saved **unfiltered**, in arrival order, to `output.log` in the run folder
(§18.5) — a single combined file — and is displayed live unless the log
session's show policy (below) hides it. Connector lines (sentinel, process id)
are excluded (§18.2).

**2. The runner log stream** — optional. A runner that offers
`log_session(serial, options, program)` returns a **Session** for one run
(`program` = `{ path, name }`, the staged device-side path and its base name),
or `nil, err` when `options` are invalid. The Session is:

| Member | Type | Purpose |
|--------|------|---------|
| `clear` | spec\|nil | Run before execution, best-effort (e.g. flush the device's log buffer so the run's log starts clean) |
| `stream(pid)` | spec | A long-running command whose output lines are the device log for this run; started once `parse_pid` reports the program's process id (`pid` is `nil` when the runner has no `parse_pid`, in which case core starts it just before `exec`) |
| `receive(line) → string\|nil` | function | The runner's receive-side filter: returns the line to keep (possibly cleaned), or `nil` to drop it |
| `display(line) → string\|nil` | function | The runner's display filter over kept lines: returns the text to show, or `nil` to hide it |
| `show` | `{ program, log, tail? }` | Show policy: `program` ∈ `live` \| `off`; `log` ∈ `live` \| `on_failure` \| `off`; `tail` = how many displayed log lines to print on failure |

Core writes **every kept line** (`receive` result) to `device.log` in the run
folder, whatever the show policy. It prints `display` results live when
`log = live`; when `log = on_failure` it prints the last `tail` displayed lines
after a failed run (non-zero status, lost status, crash, or failed tests);
`off` prints nothing. `program = off` hides program output from the terminal
(it is still saved). A log stream that cannot start, or dies, is a warning in
the summary — never a run failure. Core never interprets the lines; the saved
file and what is shown are exactly what the runner's functions return.

**Log options.** Options reach the runner **opaquely**, as a map from option
name to value, merged from two sources, later winning per key:

1. the launch configuration's `device_log` table (e.g.
   `"device_log": { "show": "both", "level": "W" }`);
2. per-invocation overrides: `--log key=value` on the command line (§16.34),
   repeatable, forwarded verbatim as strings.

Core does not know any option name. The runner validates the merged map and
rejects an unknown key or invalid value with an error naming it, which fails the
run before any device-side effect (§18.5 step 1). Defaults, and how they depend on
what is being run, are the runner's. A runner MUST treat log options as data: no
option value may become a program, a path to execute, or device command text
other than a quoted argument. `device_log` is therefore **not** program-bearing
and is honored from shared configuration (§17.6).

**Later (implementation step, not a contract change):** the editor's device log
view (§11.3) becomes a generic record view whose line parser, receive-side
prefilter, interactive filter and rendering are supplied by the module or
runner that owns the log format; the view keeps only the stream, the bounded
ring buffer, rendering cadence, pause/clear, and a free-text filter over the
rendered line. Log-format knowledge then lives only in platform plugins, and
the same functions back both the editor view and the runner's `receive` /
`display`.
