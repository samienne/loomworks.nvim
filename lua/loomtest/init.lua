--- loomtest/init.lua — Test explorer for Neovim.
---
--- Test-first test explorer: discovery comes from adapters (build system,
--- test runners), not from source file scanning. Source locations are
--- optional metadata for navigation and gutter marks.
---
--- Independent from loomworks — never requires loomworks directly.
--- Integration goes through the TestAdapter interface.

local M = {}

--- @type loomtest.TestAdapter[]
local _adapters = {}

--- @type table|nil loomtest configuration
local _config = nil

--- @type table<string, loomtest.TestNode> id → node
local _nodes = {}

--- @type loomtest.TestNode[]
local _node_list = {}

--- Default configuration.
local DEFAULT_CONFIG = {
    position = "right",
    size = 40,
    auto_open = false,
    auto_run = false,
    show_passed = true,
    keys = {
        toggle = "<leader>ts",
        run = "<leader>tt",
        run_file = "<leader>tf",
        run_all = "<leader>ta",
        output = "<leader>to",
    },
}

--- Setup loomtest with user configuration.
--- @param opts? table user config overrides
function M.setup(opts)
    _config = vim.tbl_deep_extend("force", DEFAULT_CONFIG, opts or {})

    -- Register keymaps
    local keys = _config.keys
    if keys.toggle then
        vim.keymap.set("n", keys.toggle, M.toggle, { desc = "Toggle test explorer" })
    end
    if keys.run then
        vim.keymap.set("n", keys.run, M.run_nearest, { desc = "Run test at cursor" })
    end
    if keys.run_file then
        vim.keymap.set("n", keys.run_file, M.run_file, { desc = "Run tests in file" })
    end
    if keys.run_all then
        vim.keymap.set("n", keys.run_all, M.run_all, { desc = "Run all tests" })
    end
    if keys.output then
        vim.keymap.set("n", keys.output, M.show_output, { desc = "Show test output" })
    end

    -- Register commands
    vim.api.nvim_create_user_command("LoomtestToggle", M.toggle, {})
    vim.api.nvim_create_user_command("LoomtestRun", M.run_nearest, {})
    vim.api.nvim_create_user_command("LoomtestRunFile", M.run_file, {})
    vim.api.nvim_create_user_command("LoomtestRunAll", M.run_all, {})
    vim.api.nvim_create_user_command("LoomtestRefresh", M.refresh, {})
    vim.api.nvim_create_user_command("LoomtestOutput", M.show_output, {})
end

--- Register a test adapter.
--- @param adapter loomtest.TestAdapter
function M.register_adapter(adapter)
    -- Replace existing adapter with same name
    for i, a in ipairs(_adapters) do
        if a.name == adapter.name then
            _adapters[i] = adapter
            return
        end
    end
    _adapters[#_adapters + 1] = adapter
end

--- Unregister a test adapter by name.
--- @param name string
function M.unregister_adapter(name)
    for i, a in ipairs(_adapters) do
        if a.name == name then
            table.remove(_adapters, i)
            return
        end
    end
end

--- Get all registered adapters.
--- @return loomtest.TestAdapter[]
function M.adapters()
    return _adapters
end

--- Get the current configuration.
--- @return table
function M.config()
    return _config or DEFAULT_CONFIG
end

-- ---------------------------------------------------------------------------
-- Test tree management
-- ---------------------------------------------------------------------------

--- Get all test nodes as a flat list.
--- @return loomtest.TestNode[]
function M.nodes()
    return _node_list
end

--- Get a test node by ID.
--- @param id string
--- @return loomtest.TestNode|nil
function M.get_node(id)
    return _nodes[id]
end

--- Replace the entire test tree with new nodes.
--- @param nodes loomtest.TestNode[]
function M.set_nodes(nodes)
    _node_list = nodes
    _nodes = {}
    for _, node in ipairs(nodes) do
        _nodes[node.id] = node
    end
end

--- Apply test results to the current tree.
--- @param results loomtest.TestResult[]
function M.apply_results(results)
    for _, r in ipairs(results) do
        local node = _nodes[r.test_id]
        if node then
            node.status = r.status
            node.message = r.message
            node.duration = r.duration
            node._output = r.output
            node._errors = r.errors
        end
    end
    -- Propagate status to parents: failed if any child failed
    for _, node in ipairs(_node_list) do
        if node.parent then
            local parent = _nodes[node.parent]
            if parent and node.status then
                if node.status == "failed" or node.status == "errored" then
                    parent.status = "failed"
                elseif not parent.status or parent.status == "passed" then
                    parent.status = node.status
                end
            end
        end
    end
end

--- Clear all test data.
function M.clear()
    _node_list = {}
    _nodes = {}
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

--- Discover tests from all adapters.
--- @param callback? fun() called when discovery completes
function M.discover(callback)
    local all_nodes = {}
    local pending = #_adapters
    if pending == 0 then
        M.set_nodes({})
        if callback then callback() end
        return
    end

    for _, adapter in ipairs(_adapters) do
        adapter.discover_async(function(nodes)
            if nodes then
                for _, node in ipairs(nodes) do
                    all_nodes[#all_nodes + 1] = node
                end
            end
            pending = pending - 1
            if pending == 0 then
                M.set_nodes(all_nodes)
                -- Update signs for open buffers
                require("loomtest.signs").update_all()
                -- Refresh explorer if open
                local explorer = require("loomtest.explorer")
                if explorer.is_open() then
                    explorer.refresh()
                end
                if callback then callback() end
            end
        end)
    end
end

--- Refresh: invalidate all adapters and re-discover.
function M.refresh()
    for _, adapter in ipairs(_adapters) do
        adapter.invalidate()
    end
    M.clear()
    M.discover()
end

--- Find the adapter that owns a test ID.
--- @param test_id string
--- @return loomtest.TestAdapter|nil
function M.find_adapter(test_id)
    -- For now, return the first adapter. Multi-adapter support would
    -- need ID prefixing or adapter-per-node tracking.
    return _adapters[1]
end

--- Run a specific test by ID.
--- @param test_id string
function M.run(test_id)
    local adapter = M.find_adapter(test_id)
    if not adapter then return end

    local node = _nodes[test_id]
    if not node then return end

    local spec
    if node.type == "suite" then
        spec = adapter.run_suite(test_id)
    else
        spec = adapter.run(test_id)
    end
    if not spec then return end

    require("loomtest.runner").execute(adapter, spec, { test_id })
end

--- Run all tests.
function M.run_all()
    local adapter = _adapters[1]
    if not adapter then return end

    local spec = adapter.run_all()
    if not spec then return end

    -- Collect all runnable test IDs
    local ids = {}
    for _, node in ipairs(_node_list) do
        if node.type == "test" then
            ids[#ids + 1] = node.id
        end
    end

    require("loomtest.runner").execute(adapter, spec, ids)
end

--- Run test at cursor.
function M.run_nearest()
    local bufnr = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = cursor[1]

    for _, adapter in ipairs(_adapters) do
        local test_id = adapter.get_cursor_test(bufnr, line)
        if test_id then
            M.run(test_id)
            return
        end
    end

    vim.notify("loomtest: no test at cursor", vim.log.levels.INFO)
end

--- Run all tests in the current file.
function M.run_file()
    local bufnr = vim.api.nvim_get_current_buf()
    local buf_path = vim.api.nvim_buf_get_name(bufnr)
    if buf_path == "" then return end

    local norm_path = buf_path:gsub("\\", "/"):lower()

    -- Find all tests in this file
    local file_ids = {}
    for _, node in ipairs(_node_list) do
        if node.file and node.file:gsub("\\", "/"):lower() == norm_path and node.type == "test" then
            file_ids[#file_ids + 1] = node.id
        end
    end

    if #file_ids == 0 then
        vim.notify("loomtest: no tests in this file", vim.log.levels.INFO)
        return
    end

    -- Use the first adapter's run_all with file filter
    local adapter = _adapters[1]
    if not adapter then return end

    local spec = adapter.run_all({ file = buf_path })
    if not spec then return end

    require("loomtest.runner").execute(adapter, spec, file_ids)
end

--- Toggle explorer panel.
function M.toggle()
    require("loomtest.explorer").toggle()
end

--- Show output of the most recently run (or selected) test.
function M.show_output()
    require("loomtest.explorer").show_output()
end

return M
