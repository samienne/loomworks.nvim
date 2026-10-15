--- loomtest/types.lua — Type definitions for the test explorer.
---
--- These types define the contract between loomtest core and adapters.
--- Adapters implement TestAdapter; loomtest core works with TestNode,
--- TestResult, TestError, and RunSpec.

--- @class loomtest.TestAdapter
--- @field name string unique adapter name
--- @field description fun(): string|nil context for explorer header
--- @field discover fun(): loomtest.TestNode[]|nil
--- @field discover_async fun(callback: fun(nodes: loomtest.TestNode[]|nil))
--- @field run fun(test_id: string, opts?: table): loomtest.RunSpec|nil
--- @field run_all fun(opts?: table): loomtest.RunSpec|loomtest.RunSpec[]|nil several specs run one after another
--- @field run_suite fun(suite_id: string, opts?: table): loomtest.RunSpec|nil
--- @field parse_results fun(output_path: string, spec?: loomtest.RunSpec): loomtest.TestResult[]|nil spec = the RunSpec that produced the file
--- @field invalidate fun()
--- @field get_cursor_test fun(bufnr: number, line: number): string|nil
--- @field ensure_built? fun(test_ids: string[], callback: fun(ok: boolean)) optional: build test targets before running
--- @field start? fun(selection: string[]|nil, opts: { no_build: boolean }, sink: loomtest.RunSink): loomtest.RunHandle|nil optional: an adapter-executed run (LOOMTEST.md §3) — when present loomtest calls it for every run (selection nil = run all) instead of run / run_suite / run_all / ensure_built / parse_results
--- @field status? fun(): loomtest.AdapterStatus|nil optional: the explorer header's status (LOOMTEST.md §4.2), replacing the description; `blocked` refuses run, debug and refresh with its text

--- @class loomtest.AdapterStatus
--- @field text string e.g. "tests: waiting for the workspace daemon"
--- @field level string "info" | "warn" | "error"
--- @field blocked boolean run, debug and refresh are refused with `text`

--- An adapter-executed run's report channel (LOOMTEST.md §3).
--- @class loomtest.RunSink
--- @field status fun(updates: { id: string, status: string, duration?: number, message?: string }[]) node statuses by exact id
--- @field done fun(ok: boolean, err?: string) the run ended

--- @class loomtest.RunHandle
--- @field cancel fun()

--- @class loomtest.TestNode
--- @field id string unique identifier
--- @field name string display name
--- @field type string "target" | "suite" | "test" (adapter-supplied suites are shown as given, never inferred)
--- @field parent string|nil parent node id
--- @field file string|nil absolute source file path
--- @field line number|nil 1-based line number in source
--- @field runnable boolean whether this node can be executed
--- @field status string|nil "passed"|"failed"|"skipped"|"errored"|"running"|"pending"|"queued"|nil (`queued` shows as pending)
--- @field message string|nil last failure message
--- @field duration number|nil last duration in milliseconds
--- @field _output string|nil captured stdout/stderr from the last run
--- @field _errors loomtest.TestError[]|nil assertion error locations from the last run

--- @class loomtest.RunSpec
--- @field cmd string[] command and arguments
--- @field cwd string|nil working directory
--- @field env table|nil environment variables
--- @field output_path string|nil path for structured result output
--- @field prepare (fun(): boolean, string|nil)|nil runs when the step executes, before its program (e.g. a saved launch entry's deploy); `false, err` fails the step without running it
--- @field test_id string|nil the node a failed `prepare` marks failed

--- @class loomtest.TestResult
--- @field test_id string matches a TestNode id
--- @field status string "passed"|"failed"|"skipped"|"errored"
--- @field disabled boolean|nil a skipped test that was disabled (gtest DISABLED_, result="suppressed"), not run at all; a test that merely did not run is skipped without it
--- @field message string|nil failure message or error output
--- @field output string|nil full test output text
--- @field errors loomtest.TestError[]|nil error locations
--- @field duration number|nil duration in milliseconds

--- @class loomtest.TestError
--- @field message string error/assertion message
--- @field file string|nil absolute source file path
--- @field line number|nil 1-based line number

return {}
