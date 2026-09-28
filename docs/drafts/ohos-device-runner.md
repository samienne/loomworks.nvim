# DRAFT — `ohos` SDK provider: device runner (loomworks-module-ohos.nvim)

<!-- This file belongs in the loomworks-module-ohos.nvim repository
     (suggested home: spec/sdks/ohos.md §"Device runner"). It is drafted here
     because the design is reviewed together with core §18. Nothing in it is
     normative for core. Log-format details shared with the harmony module are
     in harmony-device-log.md (same folder). -->

Implements core §18.2 for DevEco Studio installations. Section numbers are
local to this file.

## 1. Where the runner lives

`lua/loomworks/sdks/ohos.lua` gains `P.device_runner(sdk)`. It returns `nil`
when the installation has no `hdc` binary
(`<deveco>/sdk/default/openharmony/toolchains/hdc[.exe]`, the same resolution
`query_capabilities("harmony")` already does). The hdc path therefore comes
from the SDK installation path in the signed working copy (core §17.7) — never
from `PATH`, never from cached tool data.

All hdc knowledge moves into one plugin-local helper,
`lua/loomworks-module-ohos/hdc.lua`: argv construction (`-t <serial>`), Windows
path rendering, output-failure detection (today's `check_hdc_output` in
`harmony.lua`), `list targets` parsing, and device-shell quoting. hilog
knowledge lives in `lua/loomworks-module-ohos/hilog.lua`
(harmony-device-log.md). The runner and the harmony module both use them (§7).

## 2. Identity and capabilities

| Field | Value |
|-------|-------|
| `id` | `"ohos"` |
| `platforms` | `{ "ohos-aarch64", "ohos-arm" }` |
| `staging_base` | `/data/local/tmp/.loomworks` |
| `archive` | `true` (device `tar -xf`, toybox) |
| `digest` | `{ "sha256sum" }` <!-- VERIFY on device: toybox on HarmonyOS NEXT ships sha256sum; if not, fall back to md5sum, else nil --> |
| `combined_output` | `true` — `hdc shell` merges the program's stderr into stdout (§4) |
| `timeouts` | not overridden (core defaults: query 120 s, transfer 600 s) |

`query_capabilities(sdk, "cmake")` adds per-arch tokens:
HarmonyOS/OpenHarmony `arm64-v8a` → `"ohos-aarch64"`, OpenHarmony
`armeabi-v7a` → `"ohos-arm"` (cmake module spec §15.1). The tokens are this
provider's own vocabulary; core only compares them for equality.

## 3. Builders

All specs use `cmd = <hdc>` and never go through a host shell.

| Builder | argv (after `hdc`) | Parsing / checks |
|---------|--------------------|------------------|
| `list_devices()` | `list targets -v` | lines `<serial>\t<conn>\t<state>\t<host>`; skip `[Empty]`; `state = online` iff `Connected`; `properties = { connection = conn }`. Non-verbose output (bare serial per line) accepted too |
| `push(s, l, r)` | `-t s file send <l> <r>` | `<l>` rendered with backslashes on Windows (hdc treats forward-slash paths as relative). `check_output` = shared hdc failure detector (`[Fail]`, `error:` lines) |
| `pull(s, r, l)` | `-t s file recv <r> <l>` | same; plus core verifies `l` exists |
| `exec(s, req)` | `-t s shell <script>` — `<script>` is **one** argv element | see §4 |
| `parse_exit(line, n)` | — | matches `^__LW_EXIT_<n>=(%d+)$` after CR strip |
| `parse_pid(line, n)` | — | matches `^__LW_PID_<n>=(%d+)$` after CR strip |
| `terminate(s, n, pid)` | `-t s shell kill <pid>; sleep 1; kill -9 <pid>` (one element) | `pid` is an integer from `parse_pid`; without it nothing is sent |
| `crash_snapshot(s)` | `-t s shell ls /data/log/faultlog/faultlogger/` | set of names matching `^cppcrash%-` |
| `crash_collect(b, a)` | — | `/data/log/faultlog/faultlogger/<name>` for names in `a` not in `b` |
| `runtime_files(tool)` | — | `libc++_shared.so` from the kit's native sysroot, **always** staged beside the artifact (0.9 MB; harmless when the program links the static STL — the runner sees only the tool, not the configuration's `OHOS_STL`) |
| `log_session(s, opts, program)` | — | §5 |

Directory sends (`hdc file send <dir>`) are never used — they are unreliable;
core stages file by file or as one archive.

## 4. Device-shell rendering (`exec`) and connector behaviour

Verified on a device (hdc from DevEco `openharmony/toolchains`, spawned with an
argv list and no host shell):

- **One argument.** Everything after `shell` passed as **one** argv element
  reaches the device `sh` intact: `hdc -t S shell "sh -c 'echo A1=[$1] A2=[$2]' x 'one arg' two"`
  printed `A1=[one arg] A2=[two]`. The runner therefore renders the whole device
  command as one element, with POSIX single-quote quoting (`'` → `'\''`) of
  every device-side argument.
- **Live streaming.** `hdc shell` output arrives line by line while the program
  runs, also when hdc's stdout is a pipe (a `echo tick; sleep 1` loop arrives one
  line per second). No write-to-file-and-pull fallback is needed. Lines end in
  CRLF; core normalizes.
- **Merged stderr.** The device program's stderr arrives merged into hdc's
  stdout (hdc's own stderr stays empty): `echo out; echo err 1>&2; exit 3`
  yields `out\r\nerr\r\n` on stdout. Hence `combined_output = true`; the run
  folder's `output.log` is one combined stream.
- **No exit status.** hdc exits 0 whatever the remote status (the example
  above: hdc rc 0), which is why the nonce-tagged sentinel is authoritative.

The script, built from the structured request:

```sh
cd '<cwd>' || { echo __LW_EXIT_<n>=126; exit; }
LD_LIBRARY_PATH='<d1>:<d2>' K='<V>' sh -c 'echo __LW_PID_<n>=$$; exec "$0" "$@"' '<argv1>' '<argv2>' …
echo __LW_EXIT_<n>=$?
```

joined with `;` into the single `shell` argument. Env **names** are emitted
unquoted — a quoted name is not an assignment in `sh` — which is safe because
core has already restricted them to `[A-Za-z_][A-Za-z0-9_]*`. The inner
`sh -c … exec` makes the announced pid the program's own pid (needed for
`hilog -P`, §5, and `terminate`), while the outer shell survives to print the
sentinel. The nonce is alphanumeric, so the sentinel and pid lines need no
quoting. The runner's unit tests cover arguments containing `'`, `"`, `;`,
`$(x)` and spaces; the first device smoke test repeats that case end to end
(the verified example used only single quotes).

Known pitfalls handled here, not in core:

- hdc exits 0 when the device rejects an operation → `check_output`.
- hdc prints `[Fail]` yet exits 0 → `check_output` on push/pull/exec (connector
  lines only).
- A program crash yields status 139 and `Signal 11 (core dumped)`; the new
  `cppcrash-*` faultlog is collected by §3.
- hdc can hang forever after a disconnect → core's hard timeouts and liveness
  watch (core §18.8) apply to every spec above.

## 5. Logging (core §18.13 runner log stream)

Program output (stdout+stderr, combined) is core's; the runner adds the device
log — **hilog** — exactly the way the Neovim device-log view handles it today
(harmony-device-log.md has the parser, filters and option vocabulary, shared
with the harmony module).

`log_session(serial, options, program)`:

1. **Validate options** against the vocabulary (harmony-device-log.md §3):
   unknown key or bad value → `nil, "device_log: unknown option 'x' (known: show,
   prefilter, level, tag, proc, grep, exclude, tail)"`.
2. **Return the session:**

| Member | Value |
|--------|-------|
| `clear` | `hdc -t s shell hilog -r` (as `device_log_clear` does) |
| `stream(pid)` | `hdc -t s shell hilog -P <pid>` — **only** `-P`. No `-L` (it suppresses some native log paths), no `-t`/`-T` (native `OH_LOG_Print` lands on type `core`; tag filtering is client-side). hilog first prints the buffered records for the pid, then follows, so records logged between exec and stream start are not lost |
| `receive(line)` | sanitize → parse → **session prefilter** (mode `prefilter`, pid, program name as the proc to match). Unparseable lines are kept raw (they reveal connector problems). Returns the sanitized line or `nil` |
| `display(line)` | parse → **soft filter** (`level`, `tag`, `proc`, `grep`, `exclude`; AND) → compact rendering; `nil` when filtered out |
| `show` | from option `show` (below) |

**Defaults for a native executable** (the only thing the runner runs):

| Option | Default |
|--------|---------|
| `show` | `stdout` → `{ program = live, log = on_failure, tail = 30 }` |
| `prefilter` | `app-related` (pid OR proc) — the device stream is already restricted by `-P`, and a native process's proc column can be truncated or absent, which `strict` would drop <!-- VERIFY on device: proc column shape for a native process; only affects `strict` --> |
| `level` | `W` while hilog is shown only on failure; `I` when `show` is `hilog` or `both` |

`show = hilog` → `{ program = off, log = live }` (stdout still saved);
`show = both` → `{ program = live, log = live }`. The full prefiltered hilog is
always saved to `device.log` in the run folder, independent of `show` and of
the soft filter.

Examples: `lw run P Runner --log show=both --log level=D --log tag=Scene`;
launch configuration `"device_log": { "show": "both", "grep": "FAILED" }`.

## 6. Staging layout for the LumeScene case

Build dir `B`, exe at `B/test/unittest/api_unit_test/LumeSceneAPITestRunner`,
the `_CopyDeps` target places `libAGPEngineDLL.so` and `plugins/*.so` beside it,
assets at `B/test/assets/test_data` (`<exe>/../../assets/test_data`). The
project's local or shared config:

```json
"LumeScene": {
    "cmake": {
        …,
        "device": {
            "stage":   [ "test/unittest/api_unit_test/*.so",
                         "test/unittest/api_unit_test/plugins/*.so" ],
            "archive": [ "test/assets/**" ]
        }
    }
}
```

Device root `R = /data/local/tmp/.loomworks/<workspace>/<unit>/`:

```
R/test/unittest/api_unit_test/LumeSceneAPITestRunner   (artifact, chmod 755)
R/test/unittest/api_unit_test/libc++_shared.so         (runtime_files)
R/test/unittest/api_unit_test/libAGPEngineDLL.so       (stage)
R/test/unittest/api_unit_test/plugins/*.so             (stage, 6 files)
R/test/assets/test_data/…                              (one tar, 51 MB, unpacked)
```

`library_dirs` = `R/test/unittest/api_unit_test`, `…/plugins` (every dir
holding a staged `.so`). Second run: only changed files are sent; the archive
is skipped when its member digests are unchanged.

## 7. The harmony module after this change

- `M.list_devices` delegates to the profile SDK's runner (`list_devices` +
  `parse_devices`) — one hdc invocation shape, one parser, and the device
  registry holds one Device per serial whichever path listed it.
- `device_install` / `device_launch` / `device_stop` / `device_pid` /
  `device_log*` stay in the module (HAP semantics: `install`, `aa start`,
  `hilog`), but build their argv through the shared `hdc.lua` helper, reuse its
  failure detector, and take hilog parsing/filtering from `hilog.lua`.
- The `PATH` fallback for hdc in `list_devices` is **removed** (core §17.7: the
  program comes from the SDK installation). Acceptable: the harmony module
  already requires an SDK for builds (graceful-degradation policy).
- Future: a native (non-HAP) executable in a harmony project could use the same
  runner; not needed now.

## 8. Device-farm lock

The prior-art harness serialises on a farm-wide per-serial lock
(`~/util_locks/<serial>.lock`) taken by the farm's own library. Core §18.7 keeps
its own per-user lock; `LOOMWORKS_DEVICE_LOCK_DIR` can point it at the farm's
directory, but lock-file format compatibility is validated only when such a
farm is integrated. This provider adds nothing for it.
