--- Plugin/binary split: which side every Lua module under lua/ belongs to.
--- See ARCHITECTURE.md "Plugin/binary boundary". Read by
--- tests/split_boundary_spec.lua.
---
--- Sides:
---   plugin  the Neovim plugin: it talks to `lw` only through the daemon protocol.
---   shared  code both sides load, vendored byte-identical from loomworks
---           (samienne/loomworks): scripts/vendor.sh copies it and records it
---           in VENDOR.MANIFEST. Never edited here; `M.vendored()` reads the
---           manifest, and the guard test requires the shared side to be
---           exactly the vendored modules.
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
    "^loomworks%.status_source$",    -- where the status page's body reads (spec §19.13 "The workspace view", 5n)
    "^loomworks%.fidget$",
    "^loomworks%.reload$",
    "^loomworks%.auto_load$",
    "^loomworks%.lw_init$",
    -- A bare language-server program resolved from absolute PATH entries
    -- only (the LSP integrations' `rpc.start`).
    "^loomworks%.lsp_server_cmd$",
    "^loomworks%.device_log$",       -- nvim buffer view of a device log stream
    "^loomworks%.task_launch$",      -- the editor's own overseer tasks: a launched program, a device log
    "^loomworks%.views$",            -- the editor view store (spec §19.13 "Two sources, one shape")
    "^loomworks%.version$",          -- the plugin's own version (its CHANGELOG)
    "^loomworks%.daemon%.client%.",  -- the editor's daemon client: relay, version range, settings
    "^loomworks%.daemon%.observer$", -- becomes loomworks.client.session
    "^loomworks%.daemon%.editor_retire$", -- the observer's retirement decisions (spec §19.16)
    "^loomworks%.daemon%.remote_task$",
    "^loomworks%.daemon%.editor_ops$", -- the editor's operations as daemon calls (spec §19.16, step 5k)
    "^loomworks%.daemon%.facade$",   -- the public API's daemon-mode calls by ids (spec §19.16 "Public API", 6b-alpha)
    "^loomworks%.daemon%.launch_ref$", -- a `Launch/1.targets` record the editor launches (step 6b-alpha)
    "^loomworks%.daemon%.task_runner$", -- daemon tasks in overseer (spec §19.16 "Tasks in the task runner")
    "^loomworks%.provision%.",       -- the host binary the editor launches (spec §19.16)
    "^loomworks%.health$",           -- :checkhealth loomworks
    "^loomtest$",
    "^loomtest%.",
    "^lualine%.",
}

M.shared = {
    -- The wire protocol's helpers: the message envelope and a task output
    -- frame's bytes (runtime); the schema reader, the document set, the
    -- transcript lint and the conformance engine (tests).
    "^loomworks%.proto%.bytes$",
    "^loomworks%.proto%.envelope$",
    "^loomworks%.proto%.schema$",
    "^loomworks%.proto%.documents$",
    "^loomworks%.proto%.schema_check$",
    "^loomworks%.proto%.conformance$",
    -- The LSP configuration state (`LspConfig/1`): the editor's LSP layer
    -- reads it, the daemon serves it.
    "^loomworks%.lsp_config$",
    -- Pure-Lua SHA-256 (lsp_config's environment digest; the editor's
    -- provision/sha256 uses it when vim.fn.sha256 is not binary-safe).
    "^loomworks%.sha256$",
    -- The tests view's state (`view.Tests/1`).
    "^loomworks%.test_state$",
    -- A device log's lines as records (parse, prefilter, normalize).
    "^loomworks%.device_log_records$",
    -- The upward workspace-root search: the editor's auto-load and `lw` bind
    -- to the same workspace from the same directory.
    "^loomworks%.root_finder$",
    -- Descriptions: normalisation and the inert display helpers.
    "^loomworks%.description$",
}

--- The module names of the vendored Lua files (VENDOR.MANIFEST), sorted.
--- @param root string the repository root
--- @return string[]
function M.vendored(root)
    local out = {}
    for line in io.lines(root .. "/VENDOR.MANIFEST") do
        local path = line:match("^%x+  (lua/.+)%.lua$")
        if path then
            out[#out + 1] = path:gsub("^lua/", ""):gsub("/init$", ""):gsub("/", ".")
        end
    end
    table.sort(out)
    return out
end

local binary_toplevel = {
    "api_versions", "build_dir", "build_dir_claims", "build_lock", "build_run", "cache", "cli", "cli_color",
    "cli_options", "cmake_kits", "compiler_cache", "config", "config_editor",
    "config_env", "config_transfer", "config_unit", "configuration",
    "configuration_set", "core", "cpp_compilers", "data_model", "debug_config", "deletion_plan", "dependency",
    "deploy", "device", "dir_identity", "env_policy", "events",
    "exe", "expand", "file_tracker", "future", "gtest", "health_cache",
    "housekeeping", "inventory", "io", "languages", "launch_configuration", "launch_target",
    "launcher_health", "lock_break", "lock_record", "log", "lsp_db_cleanup", "merge", "migrate",
    "model_commands", "module", "msvc", "notify", "op_lock", "operation", "overseer", "paths", "plugin_loader",
    "proc", "profile", "program_fields", "project", "release_notes",
    "release_notice", "reserved_compiler", "reset_plan",
    "run_prep", "runenv", "save_guard", "sdk", "submodules", "suggestions",
    "target", "term", "test_plan", "test_targets", "test_unit", "tool", "tool_cache", "trust", "txn", "types", "user",
    "variables", "view_state", "workspace", "workspace_view",
}

local binary_daemon = {
    "auth", "calls", "client", "command", "connect", "core_interfaces", "descriptor", "devices", "discover", "endpoint",
    "ensure",
    "envscope", "handle", "identity", "inspect", "interfaces", "launch", "legacy", "loopback", "maintenance", "paths", "protocol", "relay", "rlock", "rlog",
    "runner", "running", "runtime", "server", "service", "snapshot", "stdio", "tasks", "test_discover",
    "test_runs", "test_store", "tests_view", "version", "views",
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
