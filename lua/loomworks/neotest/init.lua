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

    -- Check if dir is under the workspace root
    local root = vim.fs.normalize(ws.root)
    local norm_dir = vim.fs.normalize(dir)
    if norm_dir == root or norm_dir:sub(1, #root + 1) == root .. "/" then
        return root
    end
    return nil
end

--- Filter directories during file discovery.
--- Skip build directories and .nvim.
--- @param name string directory basename
--- @return boolean true to search inside
function adapter.filter_dir(name)
    if name == "build" or name == ".nvim" or name == "node_modules" then
        return false
    end
    return true
end

--- Check if a file could contain tests.
--- @param file_path string absolute file path
--- @return boolean
function adapter.is_test_file(file_path)
    -- We rely on build-system discovery, not source parsing.
    -- Return true for C++ test source files as a hint to neotest.
    local ext = file_path:match("%.([^%.]+)$")
    if not ext then return false end
    ext = ext:lower()
    if ext == "cpp" or ext == "cc" or ext == "cxx" or ext == "c" then
        local name = vim.fn.fnamemodify(file_path, ":t:r"):lower()
        return name:match("test") ~= nil
    end
    -- TypeScript/JavaScript test files
    if ext == "ts" or ext == "tsx" or ext == "js" or ext == "jsx" then
        return file_path:match("%.test%.") ~= nil
            or file_path:match("%.spec%.") ~= nil
            or file_path:match("/tests?/") ~= nil
    end
    return false
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
    local norm_path = vim.fs.normalize(file_path):lower()
    local best_project, best_len = nil, 0
    for _, project in pairs(ws._projects) do
        local project_path = project.path or project.key
        local project_abs = vim.fs.normalize(ws.root .. "/" .. project_path):lower()
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
--- @param entries table[] test tree entries from discover_tests
--- @param root_id string root position id
--- @param root_name string root position name
--- @param root_path string root file/dir path
--- @return table neotest.Tree
local function build_neotest_tree(entries, root_id, root_name, root_path)
    local Tree = require("neotest.types").Tree

    -- Build parent → children map
    local children_of = {}
    local top_level = {}
    local by_id = {}
    for _, entry in ipairs(entries) do
        by_id[entry.id] = entry
        if entry.parent then
            children_of[entry.parent] = children_of[entry.parent] or {}
            children_of[entry.parent][#children_of[entry.parent] + 1] = entry
        else
            top_level[#top_level + 1] = entry
        end
    end

    --- Convert an entry to a neotest tree list node recursively.
    --- @param entry table test entry
    --- @return table list node for Tree.from_list
    local function to_node(entry)
        local pos = {
            id = root_path .. "::" .. entry.id,
            type = children_of[entry.id] and "namespace" or "test",
            name = entry.name,
            path = root_path,
        }
        local node = { pos }
        local kids = children_of[entry.id]
        if kids then
            for _, child in ipairs(kids) do
                node[#node + 1] = to_node(child)
            end
        end
        return node
    end

    -- Root node
    local root_node = {
        { id = root_id, type = "dir", name = root_name, path = root_path },
    }
    for _, entry in ipairs(top_level) do
        root_node[#root_node + 1] = to_node(entry)
    end

    return Tree.from_list(root_node, function(pos) return pos.id end)
end

--- Discover test positions.
--- @param path string absolute file or directory path
--- @return table|nil neotest.Tree
function adapter.discover_positions(path)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return nil end

    local profile = lw.get_active_profile()
    if not profile then return nil end

    local stat = vim.uv.fs_stat(path)
    if not stat then return nil end

    if stat.type == "directory" then
        -- Directory-level discovery: collect tests from all ConfigUnits
        -- in the active profile under this directory
        local all_entries = {}
        for _, pp in ipairs(profile:projects()) do
            local unit = pp._config_unit
            if not unit then goto continue end

            local project = pp._project or unit._project
            if not project then goto continue end

            local project_abs = vim.fs.normalize(ws.root .. "/" .. (project.path or project.key))
            local norm_path = vim.fs.normalize(path)
            -- Only include projects under this directory
            if norm_path ~= vim.fs.normalize(ws.root)
                and project_abs:sub(1, #norm_path + 1) ~= norm_path .. "/"
                and project_abs ~= norm_path then
                goto continue
            end

            local entries = unit:discover_tests()
            if entries then
                for _, e in ipairs(entries) do
                    -- Prefix ids with project key to avoid collisions
                    all_entries[#all_entries + 1] = {
                        id = project.key .. "/" .. e.id,
                        name = project.key .. ": " .. e.name,
                        parent = e.parent and (project.key .. "/" .. e.parent) or nil,
                        runnable = e.runnable,
                        framework = e.framework,
                        executable = e.executable,
                        status = e.status,
                        -- Store original id and unit for execution
                        _original_id = e.id,
                        _config_unit = unit,
                    }
                end
            end

            ::continue::
        end

        if #all_entries == 0 then return nil end

        return build_neotest_tree(all_entries, path, vim.fn.fnamemodify(path, ":t"), path)
    else
        -- File-level discovery: find tests associated with this file
        local unit, project = resolve_config_unit(path)
        if not unit then return nil end

        local entries = unit:discover_tests()
        if not entries then return nil end

        -- For now, return all tests for the config unit when viewing a test file.
        -- Source-level filtering (which tests are in this file) would require
        -- file-api target→source mapping. We return the full tree and let
        -- neotest show all tests.
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

        return build_neotest_tree(file_entries, path, vim.fn.fnamemodify(path, ":t"), path)
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
