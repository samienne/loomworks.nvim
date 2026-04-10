--- loomworks/neotest/init.lua — Neotest adapter for loomworks.
---
--- Bridges ConfigUnit's test interface to neotest's adapter protocol.
--- Registered as a single adapter — delegates to the active profile's
--- ConfigUnits for discovery and execution.

local adapter = { name = "loomworks" }

--- Normalize a path: forward slashes, no trailing slash (for comparison).
--- @param p string
--- @return string normalized path
local function norm(p)
    return p:gsub("\\", "/"):gsub("/$", "")
end

--- Convert path to OS-native format (backslashes on Windows).
--- This matches what neotest uses internally via vim.uv and fnamemodify.
--- @param p string
--- @return string
local function to_native(p)
    if vim.fn.has("win32") == 1 then
        return p:gsub("/", "\\")
    end
    return p
end

--- Find the workspace root for a directory.
--- @param dir string absolute directory path
--- @return string|nil root path (using the same format as the input dir)
--- Cached native root path (computed once to ensure consistency).
local _cached_native_root = nil

function adapter.root(dir)
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return nil end

    -- Compute and cache the native root once
    if not _cached_native_root or norm(_cached_native_root):lower() ~= norm(ws.root):lower() then
        _cached_native_root = to_native(ws.root)
    end

    local root_lower = norm(ws.root):lower()
    local dir_lower = norm(dir):lower()
    if dir_lower == root_lower or dir_lower:sub(1, #root_lower + 1) == root_lower .. "/" then
        return _cached_native_root
    end
    return nil
end

--- Filter directories during file discovery.
--- We only need neotest to find CTestTestfile.cmake files inside build
--- directories under .nvim/. Skip everything else.
--- @param name string directory basename
--- @param rel_path string path relative to root
--- @return boolean true to search inside
--- Cached set of directories that contain or lead to test files.
local _test_dir_set = nil
local _test_dir_set_version = 0

local function get_test_dir_set()
    local file_set = get_test_file_set()
    local version = _test_file_set_version

    if _test_dir_set and _test_dir_set_version == version then
        return _test_dir_set
    end

    _test_dir_set = {}
    for file_path in pairs(file_set) do
        -- Add all parent directories up to the root
        local dir = file_path:match("^(.+)/[^/]+$")
        while dir do
            if _test_dir_set[dir] then break end -- already added parents
            _test_dir_set[dir] = true
            dir = dir:match("^(.+)/[^/]+$")
        end
    end
    _test_dir_set_version = version
    return _test_dir_set
end

function adapter.filter_dir(name)
    local name_lower = name:lower()
    if name_lower == "build" or name_lower == "node_modules"
        or name_lower == "_deps" or name_lower == "cmakefiles"
        or name_lower == ".cmake" or name_lower == "3rdparty"
        or name_lower == "googletest" or name_lower == "googlemock"
        or name_lower == "include" or name_lower == "doc"
        or name_lower == "cmake" or name_lower == "submodules" then
        return false
    end
    return true
end

--- Cached set of normalized source file paths that contain tests.
--- Rebuilt when test tree changes.
local _test_file_set = nil
local _test_file_set_version = 0

local function get_test_file_set()
    local lw = require("loomworks")
    local profile = lw.get_active_profile()
    if not profile then return {} end

    -- Simple version check: total test tree entries
    local version = 0
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit and unit._test_tree then
            version = version + #unit._test_tree
        end
    end

    if _test_file_set and _test_file_set_version == version then
        return _test_file_set
    end

    _test_file_set = {}
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit and unit._test_tree then
            for _, e in ipairs(unit._test_tree) do
                if e.file then
                    _test_file_set[norm(e.file):lower()] = true
                end
            end
        end
    end
    _test_file_set_version = version
    return _test_file_set
end

--- Check if a file could contain tests.
--- Uses filename pattern matching (fast, no state dependency).
--- @param file_path string absolute file path
--- @return boolean
function adapter.is_test_file(file_path)
    local name = file_path:match("[/\\]([^/\\]+)$")
    if not name then return false end
    local name_lower = name:lower()
    return (name_lower:match("_test%.cpp$") or name_lower:match("_test%.cc$")
        or name_lower:match("_test%.cxx$")
        or name_lower:match("^test_.*%.cpp$") or name_lower:match("^test_.*%.cc$")) ~= nil
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
    local norm_path = norm(file_path):lower()
    local best_project, best_len = nil, 0
    for _, project in pairs(ws._projects) do
        local project_path = project.path or project.key
        local project_abs = norm(ws.root .. "/" .. project_path):lower()
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
--- Groups tests by source file for navigation. Tests without source
--- locations are grouped under the sentinel file (CMakeLists.txt).
--- @param entries table[] test tree entries from discover_tests
--- @param root_id string root position id
--- @param root_name string root position name
--- @param root_path string root file/dir path
--- @param root_type? string "dir" or "file" (default "dir")
--- @return table neotest.Tree
local function build_neotest_tree(entries, root_id, root_name, root_path, root_type)
    local Tree = require("neotest.types").Tree

    root_id = to_native(root_id)
    root_path = to_native(root_path)

    local line = 1

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

        -- Always use root_path for the position path. This ensures all
        -- positions in this tree share the same path as the root (which
        -- is what neotest passed to discover_positions). Gutter marks
        -- and nearest-test lookup match by buffer path = position path.
        -- The entry.file/line are used for range only (navigation via
        -- summary 'i' key uses range to jump).
        local pos_range = { start_line, 0, line, 0 }
        if entry.line then
            pos_range = { entry.line - 1, 0, entry.line, 0 }
        end

        local pos = {
            id = root_path .. "::" .. entry.id,
            type = node_type,
            name = entry.name,
            path = root_path,
            range = pos_range,
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
--- TestUnits handle framework probing internally.
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

--- Set up event listeners for auto-populating test cache.
local _events_setup = false
local function setup_events()
    if _events_setup then return end
    _events_setup = true

    local ok, lw = pcall(require, "loomworks")
    if not ok then return end

    -- Populate test cache when workspace loads or profile changes
    lw.on("workspace_changed", function(ws)
        if ws then
            -- Delay slightly to let profile activation complete
            vim.defer_fn(ensure_test_cache, 500)
        end
    end)

    lw.on("active_set_changed", function()
        -- Invalidate all caches and re-discover
        local profile = lw.get_active_profile()
        if not profile then return end
        for _, pp in ipairs(profile:projects()) do
            local unit = pp._config_unit
            if unit then
                unit:invalidate_tests()
            end
        end
        vim.defer_fn(ensure_test_cache, 200)
    end)

    -- Populate test cache synchronously if workspace is ready.
    -- This runs during require("loomworks.neotest") which happens
    -- inside neotest.setup(). The cache must be ready BEFORE neotest
    -- starts its file scan (which happens right after setup returns).
    if lw.get_workspace() and lw.get_active_profile() then
        for _, pp in ipairs(lw.get_active_profile():projects()) do
            local unit = pp._config_unit
            if unit and not unit._test_tree then
                -- Safe: we're in the main thread during require(),
                -- not in a coroutine.
                unit:discover_tests()
            end
        end
    end
end

-- Set up events on module load
setup_events()

--- Discover test positions.
--- Returns cached test data. If not cached yet, returns nil (neotest
--- will retry on next refresh). Use ensure_test_cache() to pre-populate.
--- @param path string absolute file or directory path
--- @return table|nil neotest.Tree
function adapter.discover_positions(path)
    local ok, result = pcall(function()
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

            local project_abs = norm(ws.root .. "/" .. (project.path or project.key)):gsub("/%.$", "")
            local norm_path = norm(path)
            if norm_path ~= norm(ws.root)
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
                    file = e.file,
                    line = e.line,
                    _original_id = e.id,
                    _config_unit = unit,
                }
            end

            ::continue::
        end

        if #all_entries == 0 then return nil end

        return build_neotest_tree(all_entries, path, vim.fn.fnamemodify(path, ":t"), path)
    else
        -- File-level discovery
        local unit, project = resolve_config_unit(path)
        if not unit then return nil end

        -- Use cached data only — never block
        local entries = unit._test_tree
        if not entries then
            unit:discover_tests_async(function() end)
            return nil
        end

        -- Check if this is a source file with tests or the CMakeLists sentinel
        local norm_path = norm(path):lower()
        local is_sentinel = path:match("[/\\]CMakeLists%.txt$") ~= nil

        if is_sentinel then
            -- CMakeLists.txt: only tests WITHOUT source locations.
            -- Tests with source are discovered per-file instead.
            -- Include namespace entries that have at least one sourceless child.
            local sourceless = {}
            local ns_has_sourceless = {}
            for _, e in ipairs(entries) do
                if e.parent and not e.file then
                    sourceless[#sourceless + 1] = {
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
                    ns_has_sourceless[e.parent] = true
                elseif not e.parent then
                    -- Namespace/target — include if it has sourceless children
                    -- (checked after this loop)
                    sourceless[#sourceless + 1] = {
                        id = e.id,
                        name = e.name,
                        runnable = e.runnable,
                        framework = e.framework,
                        executable = e.executable,
                        _original_id = e.id,
                        _config_unit = unit,
                        _is_namespace = true,
                    }
                end
            end
            -- Filter: only keep namespaces that have sourceless children
            local filtered = {}
            for _, e in ipairs(sourceless) do
                if not e._is_namespace or ns_has_sourceless[e.id] then
                    e._is_namespace = nil
                    filtered[#filtered + 1] = e
                end
            end
            if #filtered == 0 then return nil end
            return build_neotest_tree(filtered, path, vim.fn.fnamemodify(path, ":t"), path, "file")
        else
            -- Source file: return only tests from this file
            local file_entries = {}
            for _, e in ipairs(entries) do
                if e.file and norm(e.file):lower() == norm_path then
                    file_entries[#file_entries + 1] = {
                        id = e.id,
                        name = e.name,
                        -- Don't set parent — these are top-level in this file
                        runnable = e.runnable,
                        framework = e.framework,
                        executable = e.executable,
                        status = e.status,
                        file = e.file,
                        line = e.line,
                        _original_id = e.id,
                        _config_unit = unit,
                    }
                end
            end
            if #file_entries == 0 then return nil end
            return build_neotest_tree(file_entries, path, vim.fn.fnamemodify(path, ":t"), path, "file")
        end
    end
    end)
    if not ok then return nil end
    return result
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

    -- Find the TestUnit for this test
    local tu = unit:_find_test_unit(original_id or pos.name)
    if not tu then return nil end

    -- Determine what to run based on position type
    local test_cmd
    if pos.type == "test" or pos.type == "namespace" then
        test_cmd = tu:test_command(original_id or pos.name)
    else
        test_cmd = tu:test_command_all()
    end
    if not test_cmd then return nil end

    -- Check if the project needs to be built first.
    local state = unit:state()
    if state == "unconfigured" or state == "configure_failed" then
        vim.schedule(function()
            vim.notify("loomworks: project needs to be configured before running tests. Use [c] in the status page.", vim.log.levels.WARN)
        end)
        return nil
    end

    local spec = {
        command = test_cmd.cmd,
        cwd = test_cmd.cwd,
        env = test_cmd.env,
        context = {
            output_path = test_cmd.output_path,
            config_unit = unit,
            test_unit = tu,
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

    -- Try to parse structured output (JUnit XML) via TestUnit
    local tu = ctx.test_unit
    if ctx.output_path and tu then
        local parsed = tu:parse_results(ctx.output_path)
        if parsed then
            if ctx.config_unit then
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

    -- For any tree node without a result, assign based on exit code.
    -- This prevents neotest from showing "unknown" status and avoids
    -- tree structure confusion.
    local overall_status = result.code == 0 and "passed" or "failed"
    for _, node in tree:iter_nodes() do
        local data = node:data()
        if not results[data.id] then
            results[data.id] = {
                status = overall_status,
                output = result.output,
            }
        end
    end

    return results
end

--- Debug: expose cache state for troubleshooting.
function adapter.debug_cache()
    local fs = get_test_file_set()
    local ds = get_test_dir_set()
    local fc, dc = 0, 0
    for _ in pairs(fs) do fc = fc + 1 end
    for _ in pairs(ds) do dc = dc + 1 end
    vim.notify("file_set=" .. fc .. " dir_set=" .. dc)
    -- Show a sample dir
    for d in pairs(ds) do
        vim.notify("  dir: " .. d)
        break
    end
    for f in pairs(fs) do
        vim.notify("  file: " .. f)
        break
    end
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
