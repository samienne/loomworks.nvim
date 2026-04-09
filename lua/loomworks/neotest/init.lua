--- loomworks/neotest/init.lua — Neotest adapter for loomworks.
---
--- Bridges ConfigUnit's test interface to neotest's adapter protocol.
--- Registered as a single adapter — delegates to the active profile's
--- ConfigUnits for discovery and execution.

local adapter = { name = "loomworks" }

--- Find the workspace root for a directory.
--- @param dir string absolute directory path
--- @return string|nil root path
function adapter.root(dir)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return nil end

    -- Normalize both to lowercase with forward slashes for comparison
    local root = ws.root:gsub("\\", "/"):lower()
    local norm_dir = dir:gsub("\\", "/"):lower()
    if norm_dir == root or norm_dir:sub(1, #root + 1) == root .. "/" then
        -- Return the root with consistent forward slashes
        return ws.root:gsub("\\", "/")
    end
    return nil
end

--- Filter directories during file discovery.
--- We only need neotest to find CTestTestfile.cmake files inside build
--- directories under .nvim/. Skip everything else.
--- @param name string directory basename
--- @param rel_path string path relative to root
--- @return boolean true to search inside
function adapter.filter_dir(name)
    return false
end

--- Check if a file could contain tests.
--- For build-system discovery, we match CMakeLists.txt at the project
--- root as the sentinel file. All ctest tests are attached to it.
--- We check against the root() result to identify the root CMakeLists.
--- @param file_path string absolute file path
--- @return boolean
function adapter.is_test_file(file_path)
    local name = file_path:match("[/\\]([^/\\]+)$")
    if name ~= "CMakeLists.txt" then return false end
    -- Only root CMakeLists: parent dir should be the project root
    local parent = file_path:sub(1, #file_path - #name - 1)
    return adapter.root(parent) == parent
end

--- Resolve the file path → project → active profile → ConfigUnit chain.
--- @param file_path string absolute file path
--- @return loomworks.ConfigUnit|nil, loomworks.Project|nil
local function resolve_config_unit(file_path)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return nil, nil end

    local profile = lw.get_active_profile()
    if not profile then return nil, nil end

    -- Find project by path prefix matching
    local norm_path = file_path:gsub("\\", "/"):lower()
    local best_project, best_len = nil, 0
    for _, project in pairs(ws._projects) do
        local project_path = project.path or project.key
        local project_abs = (ws.root .. "/" .. project_path):gsub("\\", "/"):lower()
        -- Normalize trailing /. (project path "." → root/.)
        project_abs = project_abs:gsub("/%.$", "")
        if norm_path == project_abs or norm_path:sub(1, #project_abs + 1) == project_abs .. "/" then
            if #project_abs > best_len then
                best_project = project
                best_len = #project_abs
            end
        end
    end

    if not best_project then return nil, nil end

    -- Find the ProfileProject for this project in the active profile
    local pp = profile:project(best_project.key)
    if not pp or not pp._config_unit then return nil, best_project end

    return pp._config_unit, best_project
end

--- Build a neotest position tree from ConfigUnit test entries.
--- Uses synthetic ranges since tests are discovered from the build system,
--- not from source parsing.
--- @param entries table[] test tree entries from discover_tests
--- @param root_id string root position id
--- @param root_name string root position name
--- @param root_path string root file/dir path
--- @param root_type? string "dir" or "file" (default "dir")
--- @return table neotest.Tree
local function build_neotest_tree(entries, root_id, root_name, root_path, root_type)
    local Tree = require("neotest.types").Tree

    -- Do NOT normalize paths — use exactly what neotest passed us.
    -- Neotest matches tree positions by path identity.

    -- Build parent → children map
    local children_of = {}
    local top_level = {}
    for _, entry in ipairs(entries) do
        if entry.parent then
            children_of[entry.parent] = children_of[entry.parent] or {}
            children_of[entry.parent][#children_of[entry.parent] + 1] = entry
        else
            top_level[#top_level + 1] = entry
        end
    end

    -- Assign synthetic line numbers for range (neotest needs ranges to
    -- build the tree hierarchy). Each entry gets a unique line range.
    local line = 1

    --- Convert an entry to a neotest tree list node recursively.
    --- @param entry table test entry
    --- @return table list node for Tree.from_list
    local function to_node(entry)
        local start_line = line
        local kids = children_of[entry.id]

        local node_type = kids and "namespace" or "test"
        local child_nodes = {}
        if kids then
            for _, child in ipairs(kids) do
                child_nodes[#child_nodes + 1] = to_node(child)
            end
        else
            line = line + 1
        end

        local pos = {
            id = root_path .. "::" .. entry.id,
            type = node_type,
            name = entry.name,
            path = root_path,
            range = { start_line, 0, line, 0 },
            -- Carry through metadata for execution
            _original_id = entry._original_id or entry.id,
            _config_unit = entry._config_unit,
            executable = entry.executable,
            framework = entry.framework,
        }

        local result = { pos }
        for _, cn in ipairs(child_nodes) do
            result[#result + 1] = cn
        end
        return result
    end

    -- Root node covers all lines
    local child_nodes = {}
    for _, entry in ipairs(top_level) do
        child_nodes[#child_nodes + 1] = to_node(entry)
    end

    local root_node = {
        {
            id = root_id,
            type = root_type or "dir",
            name = root_name,
            path = root_path,
            range = { 0, 0, line + 1, 0 },
        },
    }
    for _, cn in ipairs(child_nodes) do
        root_node[#root_node + 1] = cn
    end

    return Tree.from_list(root_node, function(pos) return pos.id end)
end

--- Trigger async test discovery for all ConfigUnits in the active profile.
--- Populates _test_tree caches so discover_positions can return immediately.
local function ensure_test_cache()
    local lw = require("loomworks")
    local profile = lw.get_active_profile()
    if not profile then return end

    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit and not unit._test_tree then
            unit:discover_tests_async(function() end)
        end
    end
end

--- Discover test positions.
--- Returns cached test data. If not cached yet, returns nil (neotest
--- will retry on next refresh). Use ensure_test_cache() to pre-populate.
--- @param path string absolute file or directory path
--- @return table|nil neotest.Tree
function adapter.discover_positions(path)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return nil end

    local profile = lw.get_active_profile()
    if not profile then return nil end

    -- Determine if path is a file or directory by checking extension.
    -- Avoid vim.uv.fs_stat which can deadlock in nio coroutine context.
    local is_file = path:match("%.[^/\\]+$") ~= nil
    if not is_file then
        -- Directory-level discovery: collect cached tests from all ConfigUnits
        local all_entries = {}
        local any_pending = false
        for _, pp in ipairs(profile:projects()) do
            local unit = pp._config_unit
            if not unit then goto continue end

            local project = pp._project or unit._project
            if not project then goto continue end

            local project_abs = (ws.root .. "/" .. (project.path or project.key)):gsub("\\", "/"):gsub("/%.$", "")
            local norm_path = path:gsub("\\", "/")
            if norm_path ~= ws.root:gsub("\\", "/")
                and project_abs:sub(1, #norm_path + 1) ~= norm_path .. "/"
                and project_abs ~= norm_path then
                goto continue
            end

            -- Use cached data only — never block
            local entries = unit._test_tree
            if not entries then
                -- Trigger async discovery for next time
                any_pending = true
                unit:discover_tests_async(function() end)
                goto continue
            end

            for _, e in ipairs(entries) do
                all_entries[#all_entries + 1] = {
                    id = project.key .. "/" .. e.id,
                    name = project.key .. ": " .. e.name,
                    parent = e.parent and (project.key .. "/" .. e.parent) or nil,
                    runnable = e.runnable,
                    framework = e.framework,
                    executable = e.executable,
                    status = e.status,
                    _original_id = e.id,
                    _config_unit = unit,
                }
            end

            ::continue::
        end

        if #all_entries == 0 then return nil end

        return build_neotest_tree(all_entries, path, vim.fn.fnamemodify(path, ":t"), path)
    else
        -- File-level discovery: the root CMakeLists.txt is our sentinel.
        local unit, project = resolve_config_unit(path)
        if not unit then return nil end

        -- Use cached data only — never block
        local entries = unit._test_tree
        if not entries then
            -- Trigger async discovery for next time
            unit:discover_tests_async(function() end)
            return nil
        end

        local file_entries = {}
        for _, e in ipairs(entries) do
            file_entries[#file_entries + 1] = {
                id = e.id,
                name = e.name,
                parent = e.parent,
                runnable = e.runnable,
                framework = e.framework,
                executable = e.executable,
                status = e.status,
                _original_id = e.id,
                _config_unit = unit,
            }
        end

        if #file_entries == 0 then return nil end

        return build_neotest_tree(file_entries, path, vim.fn.fnamemodify(path, ":t"), path, "file")
    end
end

--- Build a run specification for a test.
--- @param args table neotest.RunArgs { tree, extra_args?, strategy? }
--- @return table|nil neotest.RunSpec
function adapter.build_spec(args)
    local tree = args.tree
    local pos = tree:data()

    -- Find the ConfigUnit and original test id from the position
    -- Walk the tree to find a node with _config_unit metadata
    local unit, original_id
    for _, node in tree:iter_nodes() do
        local data = node:data()
        if data._config_unit then
            unit = data._config_unit
            original_id = data._original_id
            break
        end
    end

    -- If we didn't find metadata on the tree nodes, try to resolve from the position
    if not unit then
        unit = resolve_config_unit(pos.path)
        if not unit then return nil end
        -- Extract test id from position id: path::project/test:TestName → test:TestName
        local test_part = pos.id:match("::(.*)")
        if test_part then
            -- Strip project prefix if present
            original_id = test_part:match("[^/]+/(.+)") or test_part
        end
    end

    local impl = unit:_module_impl()
    if not impl then return nil end

    local project_ctx, bd = unit:_test_context()
    if not project_ctx then return nil end

    -- Determine what to run based on position type
    local test_cmd
    if pos.type == "test" or pos.type == "namespace" then
        if not impl.test_command then return nil end
        test_cmd = impl.test_command(project_ctx, bd, original_id or pos.name)
    else
        -- dir or file level: run all tests
        if not impl.test_command_all then return nil end
        test_cmd = impl.test_command_all(project_ctx, bd)
    end

    -- Build prerequisite chain: ensure built first
    -- For now, we let neotest run the command directly.
    -- The prerequisite chain (configure → build) should be triggered
    -- before running tests. Users should build first.
    -- TODO: integrate with ConfigUnit:run_test for auto-build

    local spec = {
        command = test_cmd.cmd,
        cwd = test_cmd.cwd,
        env = test_cmd.env,
        context = {
            output_path = test_cmd.output_path,
            config_unit = unit,
            position_id = pos.id,
        },
    }

    -- DAP strategy
    if args.strategy == "dap" then
        -- Find the test executable for debugging
        local executable
        for _, node in tree:iter_nodes() do
            local data = node:data()
            if data.executable then
                executable = data.executable
                break
            end
        end

        if executable and original_id then
            local filter = original_id:match("^test:(.+)$") or original_id
            spec.strategy = {
                name = "Debug " .. pos.name,
                type = "codelldb",
                request = "launch",
                program = executable,
                args = { "--gtest_filter=" .. filter },
                cwd = bd,
            }
            spec.command = nil
        end
    end

    return spec
end

--- Parse test results from the completed run.
--- @param spec table neotest.RunSpec
--- @param result table neotest.StrategyResult { code, output }
--- @param tree table neotest.Tree
--- @return table<string, neotest.Result>
function adapter.results(spec, result, tree)
    local results = {}
    local ctx = spec.context or {}

    -- Try to parse structured output (JUnit XML)
    if ctx.output_path and ctx.config_unit then
        local impl = ctx.config_unit:_module_impl()
        if impl and impl.parse_test_results then
            local parsed = impl.parse_test_results(ctx.output_path)
            if parsed then
                -- Apply results to ConfigUnit's test cache
                ctx.config_unit:_apply_test_results(parsed)

                -- Map parsed results to neotest format
                local pos = tree:data()
                for _, r in ipairs(parsed) do
                    -- Try to find the matching position in the tree
                    for _, node in tree:iter_nodes() do
                        local data = node:data()
                        local node_test_id = data._original_id or data.id:match("::(.+)$")
                        if node_test_id == r.test_id
                            or (node_test_id and node_test_id:match("[^/]+/(.+)$") == r.test_id) then
                            results[data.id] = {
                                status = r.status,
                                short = r.message,
                                output = result.output,
                            }
                            break
                        end
                    end
                end

                -- Emit event for UI updates
                local lw = require("loomworks")
                local ws = lw.get_workspace()
                if ws then
                    ws._core._deps.events.emit("test_results_changed", ctx.config_unit)
                end
            end
        end
    end

    -- If no structured results, fall back to exit code
    if not next(results) then
        local pos = tree:data()
        results[pos.id] = {
            status = result.code == 0 and "passed" or "failed",
            output = result.output,
        }
    end

    return results
end

--- Allow calling the adapter as a function for neotest setup compatibility.
--- @param opts? table adapter configuration (reserved for future use)
--- @return table adapter
setmetatable(adapter, {
    __call = function(_, opts)
        return adapter
    end,
})

return adapter
