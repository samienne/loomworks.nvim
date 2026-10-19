--- Plugin/binary split: which side every Lua module under lua/ belongs to.
--- See ARCHITECTURE.md "Plugin/binary boundary". Read by
--- tests/split_boundary_spec.lua.
---
--- Sides:
---   plugin  the Neovim plugin: it talks to `lw` only through the daemon protocol.
---   shared  host-neutral protocol client code both sides may load (pure Lua, no
---           `vim.*` beyond `vim.json`).
---   binary  the `lw` CLI/daemon: core, workspace, domain objects, modules, ...
---
--- Each entry is a Lua pattern matched against the module name (`lua/a/b.lua` ->
--- `a.b`, `lua/a/init.lua` -> `a`). Every module must match exactly one entry
--- across the three sides; a new file that matches none fails the guard test.
--- Add it here, on the side it belongs to.
---
--- `plugin/*.lua` (Neovim's plugin/ directory) is always plugin-side.

local M = {}

M.plugin = {
    "^loomworks$",
    "^loomworks%.ui%.",
    "^loomworks%.integrations%.lsp%.",
    "^loomworks%.neotest$",
    "^loomworks%.loomtest_adapter$",
    "^loomworks%.test_source$",      -- where the test adapters read tests (spec §19.16 "Tests", step 5m)
    "^loomworks%.debug$",
    "^loomworks%.session_tracker$",
    "^loomworks%.lsp$",
    "^loomworks%.lsp_source$",       -- where the LSP layer reads its state (spec §19.16 "LSP configuration")
    "^loomworks%.device_source$",    -- where the editor reads devices (spec §19.16 "Devices", step 5n)
    "^loomworks%.fidget$",
    "^loomworks%.reload$",
    "^loomworks%.auto_load$",
    "^loomworks%.device_log$",       -- nvim buffer view of a device log stream
    "^loomworks%.overseer$",         -- adapter part stays; planning half moves out later
    "^loomworks%.workspace_view$",   -- view-model part stays; orchestration moves out later
    "^loomworks%.views$",            -- the editor view store (spec §19.13 "Two sources, one shape")
    "^loomworks%.daemon%.observer$", -- becomes loomworks.client.session
    "^loomworks%.daemon%.editor_retire$", -- the observer's retirement decisions (spec §19.16)
    "^loomworks%.daemon%.remote_task$",
    "^loomworks%.daemon%.editor_ops$", -- the editor's operations as daemon calls (spec §19.16, step 5k)
    "^loomworks%.daemon%.task_runner$", -- daemon tasks in overseer (spec §19.16 "Tasks in the task runner")
    "^loomworks%.provision%.",       -- the host binary the editor launches (spec §19.16)
    "^loomworks%.health$",           -- :checkhealth loomworks
    "^loomtest$",
    "^loomtest%.",
    "^lualine%.",
}

M.shared = {
    "^loomworks%.proto$",
    "^loomworks%.proto%.",
    -- Today's sources of the future loomworks.proto: framing/message kinds and
    -- the version-range negotiation.
    "^loomworks%.daemon%.protocol$",
    "^loomworks%.daemon%.version$",
    -- The debug-adapter tables (defaults, known adapters, user.json override):
    -- the editor's debug path reads them, the daemon serves them (step 5k).
    "^loomworks%.debug_config$",
    -- The LSP configuration state (entries, db_state, db_rev, options,
    -- readiness): the editor's LSP layer reads it in-process, the daemon
    -- serves the same shape (`LspConfig/1`, step 5l).
    "^loomworks%.lsp_config$",
    -- The tests view's state (`view.Tests/1`, spec §19.13 "The tests view"):
    -- the editor builds it in-process through test_source, the daemon serves
    -- the same shape (step 5m).
    "^loomworks%.test_state$",
    -- A device log's lines as records (parse, prefilter, normalize): the
    -- editor's in-process device-log view and the daemon's
    -- `Launch/1.device_log` (step 5n B3) read the stream with the same code.
    "^loomworks%.device_log_records$",
}

local binary_toplevel = {
    "api_versions", "build_dir", "build_lock", "build_run", "cache", "cli", "cli_color",
    "cli_options", "cmake_kits", "compiler_cache", "config", "config_editor",
    "config_env", "config_transfer", "config_unit", "configuration",
    "configuration_set", "core", "cpp_compilers", "data_model", "dependency",
    "deploy", "description", "device", "dir_identity", "env_policy", "events",
    "exe", "expand", "file_tracker", "future", "gtest", "health_cache",
    "housekeeping", "inventory", "io", "languages", "launch_target",
    "launcher_health", "lock_break", "lock_record", "log", "lsp_db_cleanup", "merge", "migrate",
    "module", "msvc", "nice", "op_lock", "operation", "paths", "plugin_loader",
    "proc", "profile", "program_fields", "project", "release_notes",
    "release_notice", "reserved_compiler", "reset_plan", "root_finder",
    "run_prep", "runenv", "save_guard", "sdk", "submodules", "suggestions",
    "target", "term", "test_plan", "test_targets", "test_unit", "tool", "tool_cache", "trust", "txn", "types", "user",
    "variables", "view_state", "workspace",
}

local binary_daemon = {
    "auth", "calls", "client", "command", "connect", "core_interfaces", "descriptor", "devices", "discover", "endpoint",
    "ensure",
    "envscope", "handle", "inspect", "interfaces", "launch", "loopback", "paths", "relay", "rlock", "rlog",
    "runner", "running", "runtime", "server", "service", "snapshot", "stdio", "tasks", "test_discover",
    "test_runs", "test_store", "tests_view", "views",
}

M.binary = {
    "^main$",
    "^boot%.",
    "^loomworks%.shim$",
    "^loomworks%.shim%.",
    "^loomworks%.modules$",
    "^loomworks%.modules%.",
    "^loomworks%.sdks$",
    "^loomworks%.sdks%.",
    "^loomworks%.remote%.",
    "^loomworks%.progress$",
    "^loomworks%.progress%.",
    "^loomworks%.test_units%.",
    "^loomworks%.integrations%.inventory%.",
}
for _, name in ipairs(binary_toplevel) do
    M.binary[#M.binary + 1] = "^loomworks%." .. name .. "$"
end
for _, name in ipairs(binary_daemon) do
    M.binary[#M.binary + 1] = "^loomworks%.daemon%." .. name .. "$"
end

return M
