# DRAFT — hilog handling in loomworks-module-ohos.nvim

<!-- This file belongs in the loomworks-module-ohos.nvim repository (suggested
     home: spec/modules/harmony.md §6.1, extended). It is drafted here with core
     §18 because core §18.13 moves all log-format knowledge out of core. Nothing
     in it is normative for core. Section numbers are local to this file. -->

## 1. Principle

Core knows no device log format (core §18.13). hilog — its line format, levels,
tags, the pid/process prefilter, the soft filter, the option vocabulary and the
defaults — is owned by this plugin, in one library,
`lua/loomworks-module-ohos/hilog.lua`, used by:

- the **harmony module** (HAP apps, core §11): the Neovim device-log view;
- the **ohos device runner** (native executables, core §18): the runner log
  stream's `receive` / `display` (ohos-device-runner.md §5).

Both behave the same way the Neovim view behaves today.

## 2. Stream and records

- **Stream.** `hdc -t <serial> shell hilog [-P <pid>]` — raw, with only `-P` on
  the device. **No `-L`**: it suppresses some native log paths even at `-L D`.
  No `-t` by default (native `OH_LOG_Print(LOG_CORE, …)` lands on type `core`).
  Before a run, `hdc -t <serial> shell hilog -r` flushes the buffer
  (`device_log_clear`), so a run's log starts clean.
- **Sanitize** each line: strip BOM, ANSI CSI/OSC/single-char escapes, headless
  CSI remnants (`[41;155H`), C0 controls, trailing CR.
- **Parse** into `{ time, pid, tid, level, domain, proc?, tag, msg }` from
  `MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: msg`, falling back to the
  two-segment `DOMAIN/TAG: msg` form (`proc = nil`). A line that parses in
  neither form becomes a **raw** record (kept; it reveals connector problems).

## 3. Two-tier filtering and the option vocabulary

**Session prefilter** — applied on receive; dropped records are gone (not in
the view's ring buffer, not in the run folder's `device.log`). Raw records
always pass.

| Mode | Keeps a record when |
|------|---------------------|
| `strict` | pid matches **and** proc matches the bundle / program name (degrades to whichever of the two is known) |
| `app-related` | pid matches **or** proc matches |
| `all` | always |

Proc matching accepts an exact match, `name.`/`name:` sub-process prefixes, and
the left-truncated proc column hilog prints for long names.

**Soft filter** — applied on display; fully interactive in the editor
(re-renders from the ring buffer, no history lost). AND over every set field:
minimum `level` (`D < I < W < E < F`; `V` ranks lowest), `tag` substring, `proc`
substring, `pid`, and a pattern over the rendered line (`grep` keeps matches,
`exclude` drops matches). Raw records are hidden only by a pattern.

**Options** — the keys accepted in a launch configuration's `device_log` table
and in `lw … --log key=value` (unknown keys and bad values are rejected with an
error listing the valid ones):

| Key | Values | Meaning |
|-----|--------|---------|
| `show` | `stdout` \| `hilog` \| `both` | What is shown live (below). HAP apps have no stdout: only `hilog` applies |
| `prefilter` | `strict` \| `app-related` \| `all` | Session prefilter mode |
| `level` | `D` \| `I` \| `W` \| `E` \| `F` | Soft-filter minimum level |
| `tag` | text | Soft filter: tag contains |
| `proc` | text | Soft filter: proc contains |
| `grep` | Lua pattern | Soft filter: rendered line matches |
| `exclude` | Lua pattern | Soft filter: rendered line does not match |
| `tail` | integer | Lines printed when hilog is shown on failure only (runner) |

**Defaults by target type** (owned here, not by core):

| | `.hap` app (module, §11) | native executable (runner, §18) |
|--|--|--|
| `show` | `hilog` — the view opens live | `stdout` live; hilog captured, printed filtered (last `tail` = 30 lines) only on failure or crash |
| `prefilter` | `strict` (`device_log_strict_pid` = false keeps today's no-`-P` opt-out) | `app-related` (stream already restricted by `-P`) |
| `level` | `I` (setup `device_log_level` overrides) | `W` when shown on failure only; `I` when shown live |

The full prefiltered hilog is always saved (`device.log` in the run folder for a
runner run).

## 4. Moving hilog out of core `lua/loomworks/device_log.lua` (implementation step)

Today core's `device_log.lua` claims to let "a module supply its own line
parser and pid/process prefilter", but in fact hard-codes hilog: `parse_line`,
`make_prefilter`, `match_filter`, the level ranks and renderers are core
functions, and `session_tracker.lua` calls `device_log.make_prefilter` itself.
The step makes the claim true.

**Moves to `hilog.lua` in this plugin:**

- `parse_line` (hilog line grammar, both forms) and the record shape;
- `LEVEL_RANK`, level validation (`HILOG_LEVELS`), level → highlight mapping
  (`LEVEL_HL`), the level cycle (`off → I → W → E`) and `set_level` semantics;
- `proc_matches_bundle` and `make_prefilter` (`strict` / `app-related` / `all`);
- the field half of `match_filter` (`pid`, `proc`, `tag`, `level`);
- `render_compact` / `render_verbose` (they know the fields);
- option parsing/validation and the defaults table (§3).

**Stays in core `device_log.lua`** (becomes a generic record view):

- the streaming task (`run_streaming_task`), singleton, `start` / `stop` /
  `toggle` / `show` / `hide`;
- `LogView`: ring buffer (5000), batched flush (250 ms, 200/flush, 2000
  pending cap), autoscroll, pause, clear, header and raw records, help window;
- the free-text pattern filter over the rendered line (format-neutral);
- `sanitize_line` (generic escape stripping; hilog.lua may call it).

**New core seam** (spec change to core §11.2 when implemented): `start{}` takes
a `format` table instead of assuming hilog —
`{ parse(line) → record|nil, prefilter(record) → bool, match(filter, record,
rendered) → bool, render(record, layout) → string, highlight(record) → group|nil,
filter_keys = { { lhs, desc, fn(filter) → filter } … }, default_filter }` — and
the module supplies it through an optional hook (e.g.
`device_log_format(tool_data, { pid, bundle, options })`), replacing today's
`device_log_options` + the direct `make_prefilter` call in `session_tracker`.
`set_level` becomes a generic `update_filter(patch)`; harmony's
`set_device_log_level` / `:LoomworksDeviceLogLevel` call it with
`{ level = … }`.

**The interactive soft filter keeps working**: the view still owns the filter
table and re-renders from the ring buffer on every change; it only asks the
format to judge and render records. The level-cycle key (`cl`) and any
tag/proc keys become `filter_keys` contributed by hilog.lua, so the keymaps and
the help window are unchanged for the user. The runner's `receive` / `display`
(ohos-device-runner.md §5) call the same `hilog.lua` functions, so CLI and
editor filter identically.
