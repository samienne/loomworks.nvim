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
```

### 3.1 TestNode

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
names (gtest `Suite.Test` → suite `Suite` with child `Test`).

```
▼ ✔ LumeMetaAPITest
  ▼ ✔ API_BitfieldPropertyTest (3)
      ✔ GetValue                    2ms
      ✔ SetValue                    1ms
      ✗ Or  — Expected 4 but got 5 3ms
  ▶ ✔ API_AnimationControllerTest (18)
```

### 4.2 Header

Line 1: adapter description (profile name for loomworks).
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

## 14. Future Considerations

- Watch mode (auto-run on file save)
- Coverage display
- Standalone plugin extraction
- Additional adapters (jest, cargo test, meson)
