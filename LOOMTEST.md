# loomtest — Test Explorer Specification

## 1. Overview

loomtest is a test explorer for Neovim that discovers and runs tests
through adapter plugins. Unlike file-centric test explorers (e.g.,
neotest), loomtest is **test-first**: discovery comes from the build
system or test runner, not from scanning source files. Source locations
are optional metadata for navigation and gutter marks.

loomtest is developed within the loomworks.nvim repository but is
architecturally independent — the core module never imports loomworks.
Integration with loomworks goes through a test adapter. loomtest can be
used standalone with any adapter.

## 2. Architecture

```
┌──────────────────────────────────────────────────┐
│ loomtest core (lua/loomtest/)                    │
│                                                  │
│  init.lua ─── setup, commands, keymaps, tree     │
│  explorer.lua ─── test tree UI (Snacks.win)      │
│  runner.lua ─── execution, streaming, XML parse  │
│  signs.lua ─── gutter sign management            │
│  inline.lua ─── virtual text + diagnostics       │
│  cursor.lua ─── cursor-level test detection      │
│  types.lua ─── type definitions                  │
│                                                  │
│  Uses: Snacks.win, overseer.nvim, fidget.nvim    │
└──────────┬───────────────────────────────────────┘
           │ TestAdapter interface
┌──────────┴───────────────────────────────────────┐
│ loomworks_adapter.lua                            │
│  Bridges ConfigUnit/TestUnit to loomtest.        │
│  Registers on workspace load, refreshes on       │
│  profile switch. Auto-builds test targets.       │
└──────────────────────────────────────────────────┘
```

### 2.1 Dependency rules

- **loomtest core** depends on: Neovim API, Snacks.win, overseer.nvim.
  Does NOT depend on loomworks.
- **loomworks adapter** depends on: loomtest core (types), loomworks
  (ConfigUnit, TestUnit, Target).

## 3. TestAdapter Interface

```lua
---@class loomtest.TestAdapter
---@field name string unique adapter name
---@field description fun(): string|nil  context for explorer header
---@field discover fun(): loomtest.TestNode[]|nil
---@field discover_async fun(callback: fun(nodes: loomtest.TestNode[]|nil))
---@field run fun(test_id: string, opts?: table): loomtest.RunSpec|nil
---@field run_all fun(opts?: table): loomtest.RunSpec|nil
---@field run_suite fun(suite_id: string, opts?: table): loomtest.RunSpec|nil
---@field parse_results fun(output_path: string): loomtest.TestResult[]|nil
---@field invalidate fun()
---@field get_cursor_test fun(bufnr: number, line: number): string|nil
---@field ensure_built? fun(test_ids: string[], callback: fun(ok: boolean))
---@field status? fun(): loomtest.AdapterStatus|nil  header status (§4.2)
---@field start? fun(selection: string[]|nil, opts: table, sink: loomtest.RunSink): loomtest.RunHandle|nil
---@field debug_start? fun(test_id: string, sink: loomtest.RunSink): loomtest.RunHandle|nil
---@field result? fun(test_id: string, callback: fun(r: loomtest.TestResult|nil))
```

**Adapter-executed runs** *(step 5m)*. An adapter may run tests itself
instead of returning RunSpecs: when it has `start`, loomtest calls it for
every run (`selection` the node ids, nil for run-all; `opts.no_build`), never
`run` / `run_suite` / `run_all` / `ensure_built` / `parse_results`, and does
no streaming or output parsing of its own (§5.4, §5.5 do not apply). The
adapter reports through the sink:

```lua
---@class loomtest.RunSink
---@field status fun(updates: { id: string, status: string, duration?: number, message?: string }[])
---@field done fun(ok: boolean, err?: string)

---@class loomtest.RunHandle
---@field cancel fun()

---@class loomtest.AdapterStatus
---@field text string     e.g. "tests: waiting for the workspace daemon"
---@field level string    "info" | "warn" | "error"
---@field blocked boolean true: run, debug and refresh are refused with `text`
```

`debug_start` is the debug form (§13.1); `result` returns a node's output and
error locations on demand (§8) when the adapter keeps them rather than
loomtest. A RunSpec adapter (the in-process loomworks adapter, third-party
adapters) is unchanged.

### 3.1 TestNode

*(Step 5m.)* An adapter may supply `suite` nodes itself; when any node of a
target has `type = "suite"`, loomtest does not infer suites for that target
(§4.1). Results apply by exact `test_id` only, never by name matching, when
the adapter supplies its own suites. Ids are the adapter's and opaque to
loomtest. The status values gain `queued` (selected by a running run, not
started yet), shown as pending.

```lua
---@class loomtest.TestNode
---@field id string        unique identifier
---@field name string      display name
---@field type string      "target" | "suite" | "test"
---@field parent string|nil  parent node id
---@field file string|nil  absolute source file path
---@field line number|nil  1-based line number in source
---@field runnable boolean
---@field status string|nil  "passed"|"failed"|"skipped"|"errored"|"running"|"pending"|nil
---@field message string|nil  last failure message
---@field duration number|nil  last duration in milliseconds
```

### 3.2 RunSpec

```lua
---@class loomtest.RunSpec
---@field cmd string[]     command and arguments
---@field cwd string|nil   working directory
---@field env table|nil    environment variables
---@field output_path string|nil  path for gtest XML output
```

### 3.3 TestResult

```lua
---@class loomtest.TestResult
---@field test_id string        matches a TestNode id
---@field status string         "passed"|"failed"|"skipped"|"errored"
---@field message string|nil    failure message
---@field output string|nil     per-test stdout/stderr
---@field errors loomtest.TestError[]|nil  error locations
---@field duration number|nil   duration in milliseconds
```

### 3.4 TestError

```lua
---@class loomtest.TestError
---@field message string     error/assertion message
---@field file string|nil    absolute source file path
---@field line number|nil    1-based line number
```

## 4. Explorer UI

### 4.1 Tree structure

Tests grouped by target → suite → test. Suites inferred from test
names (gtest `Suite.Test` → suite `Suite` with child `Test`), unless the
adapter supplies suite nodes (§3.1), which are shown as given.

```
▼ ✔ LumeMetaAPITest
  ▼ ✔ API_BitfieldPropertyTest (3)
      ✔ GetValue                    2ms
      ✔ SetValue                    1ms
      ✗ Or  — Expected 4 but got 5 3ms
  ▶ ✔ API_AnimationControllerTest (18)
```

### 4.2 Header

Line 1: adapter description (profile name for loomworks). *(Step 5m.)*
When the adapter reports a `status` (§3), it replaces the description in
its level's highlight (e.g. `tests: waiting for the workspace daemon`,
`tests: daemon offers no loomworks.view.Tests/1`, `tests: workspace
unloaded`, `tests: discovering…`); while
it is `blocked`, run, debug and refresh keys show `text` as one notification
instead of acting.
Line 2: colored counts — 🧪 total ✔ passed ✗ failed ↻ running ⊘ skipped ○ unknown.
All counts always shown to prevent layout shifts.

### 4.3 Status propagation

Parent (target/suite) status derived from children:
failed > running > pending > passed > skipped > unknown.

### 4.4 Keybindings (explorer)

| Key     | Action |
|---------|--------|
| `<CR>`  | Run test/suite/target |
| `r`     | Run test/suite/target |
| `R`     | Run all tests |
| `i`     | Jump to test source |
| `o`     | Show test output |
| `e`     | Jump to first error location |
| `h`     | Fold close (or move to parent + fold) |
| `l`     | Fold open (restore cursor position) |
| `<Tab>` | Toggle fold |
| `p`     | Toggle show passed tests |
| `<C-r>` | Refresh (re-discover) |
| `q`     | Close |

### 4.5 Fold position memory

`h` on a leaf saves the node ID, folds the parent. `l` on the parent
unfolds and restores cursor to the saved node.

## 5. Test Execution

*(Step 5m.)* §5.1–§5.5 describe RunSpec adapters. With an adapter-executed
run (§3) the adapter does the build, execution and parsing (for loomworks in
the daemon, §13.1), loomtest only shows the sink's statuses and the final
state; §5.3's staleness clearing and §5.6's progress still apply.

### 5.1 Direct binary execution

Tests run via the gtest binary directly (not through ctest), using
execution specs from `ctest --show-only=json-v1` (command, env,
working directory, timeout).

### 5.2 Auto-build

`ensure_built` builds the test target via a plain overseer task (not
loomworks tracker, to avoid invalidating the test cache). Builds only
the specific test target when possible. `<leader>tA` skips the build.

### 5.3 Timestamp-based staleness

Before running, checks each test's source file mtime against the last
run time. Only clears status for tests whose source file changed.
Tests in unchanged files keep their previous results during the run.

### 5.4 Streaming

Batch processing via `vim.defer_fn` every 50ms, reading up to 20
lines per tick from the overseer buffer. Matches `[ RUN ]`, `[ OK ]`,
`[ FAILED ]` patterns for real-time status updates. Explorer refreshes
every 250ms (5 ticks). No interference with overseer's stdout handling.

### 5.5 XML results

On completion, gtest XML (`--gtest_output=xml`) provides authoritative
results. Line-by-line parsing for performance (avoids gmatch on large
strings). Self-closing `<testcase ... />` for passed tests, multi-line
for failed tests with `<failure>`, `<system-out>`, `<system-err>`.

### 5.6 Fidget progress

Shows `✔ 590 ✗ 2 / 1323 (45%)` during execution. Updates every 250ms.
Finishes cleanly on completion.

## 6. Gutter Signs

Signs placed at test source locations using `node.file` and `node.line`.
Updated on BufEnter, during test execution, and on completion.
Priority 15 (higher than diagnostic signs at 8).

Aggregation for shared lines: failed > running > skipped > passed.

## 7. Inline Annotations

### 7.1 Virtual text (extmarks)

Test-level: `✔ passed 2ms` or `✗ failed` at TEST() macro line.
Configurable via `setup({ inline = { test_result, error_detail } })`.

### 7.2 Diagnostics

Assertion-level errors published as `vim.diagnostic` (source: "loomtest").
Integrates with `<leader>d` hover, `[d`/`]d` navigation, trouble.nvim.
Diagnostic virtual text shows error message inline (LSP-consistent).
No underline. Diagnostic signs at lower priority than loomtest signs.

## 8. Test Output Viewer

### 8.1 From explorer (`o` key)

Shows per-test output from gtest XML, failure message, and error
locations. "No output captured" for passing tests. Suite/target nodes
find their first failed child.

### 8.2 From source (`<leader>to`)

Finds test at cursor, shows its output. "No test found on this line"
for non-test lines. In explorer, delegates to selected node.

### 8.3 Error navigation

`<CR>` in the output float jumps to file:line using full paths from
error data. Closes the float and opens in a non-explorer window.
`e` in the explorer jumps to first error location.

For an adapter with `result` (§3) the output, message and error locations
are read from it when shown — the output window, `e`, and the inline marks
and diagnostics of a failed node whose file is shown (§7) — once per node
until its status changes or the tree is replaced.

## 9. Source Navigation

### 9.1 Explorer → source (`i` key)

Opens test source file in a non-explorer window at the test's line.

### 9.2 Source → explorer

`<leader>ts`: toggle explorer. On open, scrolls to test at cursor.
`<leader>tg`: always open explorer and reveal test at cursor. Unfolds
parents as needed.

## 10. Global Keymaps

| Key | Action |
|-----|--------|
| `<leader>ts` | Toggle test explorer |
| `<leader>tg` | Go to test in explorer |
| `<leader>tt` | Run test at cursor |
| `<leader>tf` | Run tests in file |
| `<leader>ta` | Run all tests (with build) |
| `<leader>tA` | Run all tests (no build) |
| `<leader>to` | Show test output |

## 11. Configuration

```lua
require("loomtest").setup({
    position = "right",
    size = 40,
    auto_open = false,
    auto_run = false,
    show_passed = true,
    win = {},
    inline = {
        enabled = true,
        test_result = true,
        error_detail = true,
    },
    keys = { ... },
})
```

## 12. Profile Switching

On `active_set_changed`: clears inline annotations and diagnostics,
invalidates adapters, re-discovers tests, resets run timestamps.

## 13. Loomworks Adapter

Bridges ConfigUnit/TestUnit to the loomtest TestAdapter interface.
Registers on workspace load, re-registers on profile switch.

A ConfigUnit can have several TestUnits — the module's, plus core's
saved-targets TestUnit (specification §1.3.4, §8.9.3). The adapter follows
the owning-unit dispatch rule of specification §8.9.4: run, debug and result
parsing go through the TestUnit that owns the id; run-all and run-suite cover
every TestUnit of every ConfigUnit of the profile, never only the first
unit's first TestUnit. Saved entries appear as top-level `target:` or
`launch:` nodes (a repeated name's later occurrences suffixed `#2`, `#3`, …,
specification §8.9.2), with framework children when the program is a
recognised framework executable; the children of a `launch` entry or of a
repeated name's later occurrence carry an `@<entry id>` suffix on their ids
(e.g. `test:Suite.Case@launch:Foo`), so the same case under two entries
stays two nodes. A missing saved entry appears as an errored, non-runnable
node. A saved entry runs in its own working directory (specification §1.3.4
"Working directory").

### 13.1 Daemon mode

*(Step 5m; specification daemon.md §19.16 "Tests".)* In the editor's
`daemon` runtime mode (the default since step 5s) the adapter computes nothing about tests: the tree (units, explicit
suites, unit-scoped opaque ids, `source`), the unit states and the last
results come only from the daemon's `loomworks.view.Tests/1`, and its live
statuses from `Tests/1` `results`. It implements `start`, `debug_start`,
`result` and `status` (§3):

- **Discovery**: `discover_async` returns the view's nodes; when the view is
  `stale` and the explorer is open (or on `<C-r>`, forced) it calls
  `Tests/1.discover`, an owned overseer row, and the tree follows the view's
  `update`. A unit that is `not_configured`, `foreign` or `error` shows as
  one non-runnable node with the view's `message`; a `no_tests` unit as one
  non-runnable node with the fixed label `no tests`; a `pending` unit (not
  discovered yet in this session) as one neutral, non-runnable `not
  discovered yet` node; an unknown state as a neutral node.
- **Runs**: `start` is one `Tests/1.run_cases` (`select` the ids, none for
  run-all, `no_build` for `<leader>tA`), an owned overseer row whose stop
  cancels it; the build is in that task (`ensure_built` is not used).
  `results` signals feed the sink; another client's runs show too.
- **Debug**: `debug_start` is `Tests/1.prepare_debug` → the returned debug
  spec to `debug.run()` → `Tests/1.collect` when the session ends; no
  language or adapter is assumed. The installed-adapter check runs after
  the task's `done` (the adapter is known only from the returned spec) and
  before `debug.run()`; a missing adapter shows the install hint, starts no
  session and calls `Tests/1.collect` at once to drop the prepared token.
  `debug_start` takes one node, so debugging a file's tests debugs its one
  test; a file with several says to debug the test at the cursor.
- **Output**: `o`, `e`, inline marks and diagnostics of failed nodes read
  `Tests/1.result { id }`.
- **Status**: unloaded, disconnected, `error`/`refused`, or the interfaces
  missing → `status` is `blocked` with that text, the tree empty, signs and
  inline marks cleared; nothing is discovered or run in-process. On reconnect
  the view restores the tree and the daemon's last results (kept in the
  daemon's memory for its session).

In the deprecated `in-process` mode (`runtime.mode = "in-process"`) the adapter is the RunSpec adapter above, unchanged,
until step 6b.

## 14. Future Considerations

- Watch mode (auto-run on file save)
- Coverage display
- Standalone plugin extraction
- Additional adapters (jest, cargo test, meson)
