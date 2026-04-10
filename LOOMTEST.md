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
│  init.lua ─── setup, commands, keymaps           │
│  explorer.lua ─── test tree UI (View + widget)   │
│  signs.lua ─── gutter sign management            │
│  cursor.lua ─── cursor-level test detection      │
│  runner.lua ─── test execution orchestration     │
│  types.lua ─── type definitions                  │
│                                                  │
│  Uses: Tree widget (from loomworks.ui or shared) │
│  Uses: Snacks.win (for floating window)          │
│  Uses: overseer.nvim (for task execution)        │
└──────────┬───────────────────────────────────────┘
           │ TestAdapter interface
           │
┌──────────┴───────────────────────────────────────┐
│ Adapters                                         │
│                                                  │
│  loomworks_adapter.lua — bridges ConfigUnit/     │
│    TestUnit to loomtest. Uses loomworks API.     │
│                                                  │
│  (future) standalone adapters:                   │
│    ctest_adapter.lua — direct ctest without      │
│      loomworks                                   │
│    jest_adapter.lua — jest/vitest                 │
│    cargo_adapter.lua — cargo test                │
└──────────────────────────────────────────────────┘
```

### 2.1 Dependency rules

- **loomtest core** depends on: Neovim API, Snacks.win, overseer.nvim,
  Tree widget. Does NOT depend on loomworks.
- **loomworks adapter** depends on: loomtest core (types), loomworks
  (ConfigUnit, TestUnit).
- **loomtest core** communicates with adapters ONLY through the
  TestAdapter interface.

### 2.2 File layout

```
lua/loomtest/
├── init.lua              — setup(), register_adapter(), commands
├── explorer.lua          — test tree window (explorer widget)
├── signs.lua             — gutter sign placement and updates
├── cursor.lua            — find test at cursor position
├── runner.lua            — execute tests via overseer
└── types.lua             — TestAdapter, TestNode, TestResult types

lua/loomworks/loomtest_adapter.lua  — loomworks adapter implementation
```

## 3. TestAdapter Interface

An adapter provides test discovery, execution, and result parsing for
one test source (e.g., ctest, jest, cargo test).

```lua
---@class loomtest.TestAdapter
---@field name string unique adapter name
---@field description() → string|nil  context string for explorer header
---@field discover() → loomtest.TestNode[]|nil
---@field discover_async(callback: fun(nodes: loomtest.TestNode[]|nil))
---@field run(test_id: string, opts?: table) → loomtest.RunSpec
---@field run_all(opts?: table) → loomtest.RunSpec
---@field run_suite(suite_id: string, opts?: table) → loomtest.RunSpec
---@field parse_results(output_path: string) → loomtest.TestResult[]|nil
---@field invalidate()
---@field get_cursor_test(bufnr: number, line: number) → string|nil
```

### 3.1 TestNode

Returned by `discover()`. Represents a test, test suite, or test target
in a flat list with parent references for tree nesting.

```lua
---@class loomtest.TestNode
---@field id string        unique identifier
---@field name string      display name
---@field type string      "target" | "suite" | "test"
---@field parent string|nil  parent node id (for tree nesting)
---@field file string|nil  absolute source file path
---@field line number|nil  1-based line number in source
---@field runnable boolean whether this node can be executed
---@field status string|nil  "passed"|"failed"|"skipped"|"errored"|nil
---@field message string|nil  last failure message
---@field duration number|nil  last duration in milliseconds
```

**Node types**:
- `target` — a test executable or runner (e.g., ctest target, jest
  project). Top level. Always runnable.
- `suite` — a test suite/class/fixture (e.g., gtest suite). Groups
  tests. Runnable (runs all tests in suite).
- `test` — an individual test case. Leaf node. Always runnable.

**Adapter description**: Each adapter provides a `description()` method
that returns a human-readable string shown in the explorer header. The
loomworks adapter returns the active profile name (e.g.,
"Debug:ninja-clang-18"). This is adapter-agnostic — any adapter can
provide context about what configuration is active.

```lua
---@field description() → string|nil  context string for explorer header
```

### 3.2 RunSpec

Returned by `run()`, `run_all()`, `run_suite()`. Describes how to
execute the test(s).

```lua
---@class loomtest.RunSpec
---@field cmd string[]     command and arguments
---@field cwd string|nil   working directory
---@field env table|nil    environment variables
---@field output_path string|nil  path for structured result output
```

### 3.3 TestResult

Returned by `parse_results()`. Per-test result after execution.

```lua
---@class loomtest.TestResult
---@field test_id string        matches a TestNode id
---@field status string         "passed"|"failed"|"skipped"|"errored"
---@field message string|nil    failure message or error output
---@field output string|nil     full test output text
---@field errors loomtest.TestError[]|nil  error locations for jump-to
---@field duration number|nil   duration in milliseconds
```

### 3.4 TestError

Represents a failure location within a test. Enables "jump to failure"
in the explorer and diagnostic-style annotations in the source.

```lua
---@class loomtest.TestError
---@field message string     error/assertion message
---@field file string|nil    absolute source file path
---@field line number|nil    1-based line number
```

A single test may have multiple errors (e.g., multiple failed
assertions). The GTest XML output includes file/line for each
`<failure>` element. The explorer shows the first error; `d` key
shows all.

### 3.5 Adapter lifecycle

1. Adapter is registered via `loomtest.register_adapter(adapter)`
2. On first explorer open or explicit refresh, `discover_async()` is
   called. Results populate the test tree.
3. On test execution, `run()` / `run_all()` / `run_suite()` returns a
   RunSpec. The runner executes it via overseer.
4. On task completion, `parse_results()` extracts per-test results.
5. On profile switch or explicit refresh, `invalidate()` is called,
   then `discover_async()` re-populates.

### 3.6 get_cursor_test

```lua
---@param bufnr number buffer number
---@param line number 1-based cursor line
---@return string|nil test_id matching test, or nil
```

Given a buffer and cursor position, returns the test ID at that
location. The adapter knows how to map source locations to test IDs
(e.g., GTest helper scans for TEST macros). Returns nil if no test
is at the cursor.

Used by the "run test at cursor" command.

## 4. Explorer UI

### 4.1 Window

The explorer opens as a side panel (configurable: left, right, bottom,
float). Uses the Tree widget for rendering. Persistent — stays open
across interactions.

### 4.2 Tree structure

```
LumeMetaAPITest                    ✔  (target)
├── API_BitfieldPropertyTest          (suite)
│   ├── GetValue                   ✔  (test)
│   ├── SetValue                   ✔
│   └── Or                         ✗
├── API_AnimationControllerTest
│   ├── RunningAnimationList...    ✔
│   └── Seeking...                 ✔
└── API_LoopAnimationModifierSuite
    ├── AnimationIsLooping/Keyframe0  ✔
    └── AnimationIsLooping/Track1     ✔
```

Nodes are grouped by target → suite → test. Suites are inferred from
the test name (gtest: `Suite.Test` → suite node `Suite` with child
`Test`). This grouping is done by the explorer from the flat TestNode
list, not by the adapter.

### 4.3 Node display

```
{fold_char} {status_marker} {name} {duration}
```

Where:
- `{fold_char}` — ▶/▼ for nodes with children, blank for leaves
- `{status_marker}` — ✔ (passed), ✗ (failed), ○ (not run), ⊘ (skipped),
  spinner (running)
- `{duration}` — e.g., "12ms", shown after run (Comment highlight)

### 4.4 Keybindings (explorer window)

| Key     | Action |
|---------|--------|
| `<CR>`  | Run test/suite/target under cursor |
| `r`     | Run test/suite/target under cursor |
| `R`     | Run all tests |
| `o`     | Jump to test source (open file at line) |
| `e`     | Jump to first error location (failed tests) |
| `<Tab>` | Toggle fold |
| `p`     | Toggle show passed tests |
| `f`     | Toggle show failed tests only |
| `d`     | Show test output in float (full stdout/stderr) |
| `g`     | Refresh (re-discover) |
| `q`     | Close explorer |

### 4.5 Error navigation

When a test fails, pressing `e` on it jumps to the first error
location (file + line from `TestError`). If the test has multiple
errors, repeated `e` cycles through them.

Failed tests show the first error message inline (truncated) after
the test name in the tree:

```
✗ MyTest  — Expected 4 but got 5 (test.cpp:42)
```

### 4.6 Explorer header

Summary shown at the top of the explorer:

```
Debug:ninja-clang-18  ✔ 1200  ✗ 3  ⊘ 2  ○ 118
```

The first part is the adapter's `description()` — for loomworks this is
the active profile name. For a standalone ctest adapter it might be the
build directory basename. If no description, just the counts are shown.

### 4.7 Test output

Pressing `d` on a test opens a floating window with the full test
output (stdout + stderr). For failed tests, error locations are
highlighted and clickable (Enter on an error line jumps to that
file:line).

The output window shows:
- Test name and status
- Duration
- Full output text
- Error locations (highlighted, with file:line references)

The `:LoomtestOutput` command opens the output for the most recently
run test.

## 5. Gutter Signs

### 5.1 Sign placement

When a buffer is opened, loomtest checks if any TestNodes have `file`
matching the buffer path. If so, signs are placed at their `line`
positions.

Signs are updated when:
- Test results change (after run completion)
- Buffer is opened/entered
- Test tree is refreshed

### 5.2 Sign types

| Status    | Sign | Highlight |
|-----------|------|-----------|
| passed    | ✔    | DiagnosticOk |
| failed    | ✗    | DiagnosticError |
| skipped   | ⊘    | DiagnosticWarn |
| errored   | !    | DiagnosticError |
| not run   | ○    | Comment |

### 5.3 Multiple tests per line

Parameterized tests may share a source line. The sign shows the
aggregate status: if any failed → ✗, else if any skipped → ⊘, else ✔.

## 6. Cursor-Level Running

### 6.1 Flow

1. User presses `<leader>tt` in a source buffer
2. loomtest calls `adapter.get_cursor_test(bufnr, cursor_line)` for
   each registered adapter
3. Adapter returns the test_id at cursor, or nil
4. If found, `runner.run(adapter, test_id)` executes it
5. Results update the tree and gutter signs

### 6.2 File-level running

`<leader>tf` runs all tests whose `file` matches the current buffer.
loomtest filters the test tree (not the adapter) — any test with
matching file path is collected and passed to `adapter.run_all()` with
appropriate filter.

## 7. Commands

| Command | Description |
|---------|-------------|
| `:LoomtestToggle` | Toggle explorer panel |
| `:LoomtestRun` | Run test at cursor |
| `:LoomtestRunFile` | Run all tests in current file |
| `:LoomtestRunAll` | Run all tests |
| `:LoomtestRefresh` | Re-discover tests |
| `:LoomtestOutput` | Show output of last test |

## 8. Global Keymaps (configurable)

| Key | Command |
|-----|---------|
| `<leader>ts` | `:LoomtestToggle` |
| `<leader>tt` | `:LoomtestRun` (cursor) |
| `<leader>tf` | `:LoomtestRunFile` |
| `<leader>ta` | `:LoomtestRunAll` |
| `<leader>to` | `:LoomtestOutput` |

## 9. Integration with loomworks

The loomworks adapter (`loomworks/loomtest_adapter.lua`) bridges
loomworks domain objects to the loomtest TestAdapter interface:

- `discover()` → iterates active profile's ConfigUnits, calls
  `test_units()` → `discover()` on each TestUnit
- `run(test_id)` → finds owning TestUnit, delegates `test_command()`
- `parse_results()` → delegates to TestUnit
- `invalidate()` → calls `ConfigUnit:invalidate_tests()`
- `get_cursor_test()` → uses GTest helper to match TEST macros

The adapter registers itself on workspace load (`workspace_changed`
event) and re-registers on profile switch (`active_set_changed`).

## 10. Configuration

```lua
require("loomtest").setup({
    -- Explorer window position: "left", "right", "bottom", "float"
    position = "right",
    -- Explorer width (for left/right) or height (for bottom)
    size = 40,
    -- Auto-open explorer on first test discovery
    auto_open = false,
    -- Auto-run tests on file save
    auto_run = false,
    -- Show passed tests in explorer (toggle with 'p')
    show_passed = true,
    -- Keymaps (set to false to disable)
    keys = {
        toggle = "<leader>ts",
        run = "<leader>tt",
        run_file = "<leader>tf",
        run_all = "<leader>ta",
        output = "<leader>to",
    },
})
```

## 11. Future Considerations

- **DAP integration**: run test under debugger
- **Watch mode**: auto-run on file save
- **Coverage**: display coverage data alongside test results
- **History**: track test results over time
- **Standalone plugin**: extract from loomworks repo into separate
  package with its own adapter ecosystem
