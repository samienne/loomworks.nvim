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
--- @field run_all fun(opts?: table): loomtest.RunSpec|nil
--- @field run_suite fun(suite_id: string, opts?: table): loomtest.RunSpec|nil
--- @field parse_results fun(output_path: string): loomtest.TestResult[]|nil
--- @field invalidate fun()
--- @field get_cursor_test fun(bufnr: number, line: number): string|nil

--- @class loomtest.TestNode
--- @field id string unique identifier
--- @field name string display name
--- @field type string "target" | "suite" | "test"
--- @field parent string|nil parent node id
--- @field file string|nil absolute source file path
--- @field line number|nil 1-based line number in source
--- @field runnable boolean whether this node can be executed
--- @field status string|nil "passed"|"failed"|"skipped"|"errored"|nil
--- @field message string|nil last failure message
--- @field duration number|nil last duration in milliseconds

--- @class loomtest.RunSpec
--- @field cmd string[] command and arguments
--- @field cwd string|nil working directory
--- @field env table|nil environment variables
--- @field output_path string|nil path for structured result output

--- @class loomtest.TestResult
--- @field test_id string matches a TestNode id
--- @field status string "passed"|"failed"|"skipped"|"errored"
--- @field message string|nil failure message or error output
--- @field output string|nil full test output text
--- @field errors loomtest.TestError[]|nil error locations
--- @field duration number|nil duration in milliseconds

--- @class loomtest.TestError
--- @field message string error/assertion message
--- @field file string|nil absolute source file path
--- @field line number|nil 1-based line number

return {}
