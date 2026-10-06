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
    "^loomworks%.debug$",
    "^loomworks%.session_tracker$",
    "^loomworks%.lsp$",
    "^loomworks%.fidget$",
    "^loomworks%.reload$",
    "^loomworks%.auto_load$",
    "^loomworks%.device_log$",       -- nvim buffer view of a device log stream
    "^loomworks%.overseer$",         -- adapter part stays; planning half moves out later
    "^loomworks%.workspace_view$",   -- view-model part stays; orchestration moves out later
    "^loomworks%.daemon%.observer$", -- becomes loomworks.client.session
    "^loomworks%.daemon%.remote_task$",
    "^loomworks%.daemon%.host_binary$", -- becomes loomworks.provision.*
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
}

local binary_toplevel = {
    "api_versions", "build_dir", "build_lock", "build_run", "cache", "cli",
    "cli_options", "cmake_kits", "compiler_cache", "config", "config_editor",
    "config_env", "config_transfer", "config_unit", "configuration",
    "configuration_set", "core", "cpp_compilers", "data_model", "dependency",
    "deploy", "description", "device", "dir_identity", "env_policy", "events",
    "exe", "expand", "file_tracker", "future", "gtest", "health_cache",
    "housekeeping", "inventory", "io", "languages", "launch_target",
    "launcher_health", "lock_break", "lock_record", "log", "merge", "migrate",
    "module", "msvc", "nice", "op_lock", "operation", "paths", "plugin_loader",
    "proc", "profile", "program_fields", "project", "release_notes",
    "release_notice", "reserved_compiler", "reset_plan", "root_finder",
    "run_prep", "runenv", "save_guard", "sdk", "submodules", "suggestions",
    "target", "term", "test_unit", "tool", "trust", "txn", "types", "user",
    "variables", "workspace",
}

local binary_daemon = {
    "auth", "client", "command", "discover", "endpoint", "ensure", "envscope",
    "handle", "inspect", "launch", "loopback", "paths", "rlock", "rlog",
    "runner", "running", "runtime", "server", "service", "snapshot", "tasks",
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
