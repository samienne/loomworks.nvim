--- Configuring a profile runs configure for every unit of the profile,
--- including ones already configured (core §5.1 "Explicit configure"). Only
--- the configure a build runs automatically (§5.2) skips configured units.

local Core = require("loomworks.core")
local h = require("tests.helpers")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local real_modules = require("loomworks.modules")

local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

--- Two cmake projects (App, Lib), profile `debug` on a gcc + Ninja tool whose
--- cmake is a real (empty) file under the temp root.
local function make_core()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(root .. "/App", "p")
    vim.fn.mkdir(root .. "/Lib", "p")
    vim.fn.mkdir(root .. "/bin", "p")
    root = ((vim.uv or vim.loop).fs_realpath(root) or root):gsub("\\", "/")
    local cmake_path = root .. "/bin/cmake" .. (vim.fn.has("win32") == 1 and ".exe" or "")
    vim.fn.writefile({}, cmake_path)
    if vim.fn.has("win32") == 0 then vim.fn.setfperm(cmake_path, "rwxr-xr-x") end
    local tool = { key = "ninja-gcc-13",
        data = { compiler_id = "gcc-13", generator = "Ninja", cmake_path = cmake_path } }
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = {
                App = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
                Lib = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = { debug = { App = "Debug", Lib = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = tool.key, data = tool.data } },
        } } }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = modules_get },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = tool.key, tool_data = tool.data, tool_label = tool.key,
    } } }
    core:remerge()
    local ws = core:get_workspace()
    cmake._cmake_version_cache = { [cmake_path] = { major = 3, minor = 28 } }
    return ws, ws._profiles[1], root
end

describe("profile configure", function()
    local orig_lookup = cpp.lookup_path
    local loomworks = require("loomworks")
    local orig_get_ws = loomworks.get_workspace
    local root

    before_each(function() cpp.lookup_path = function() return nil end end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        loomworks.get_workspace = orig_get_ws
        cmake._cmake_version_cache = {}
        package.loaded["overseer"] = nil
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    --- Mock overseer: records every task spec handed to `new_task`; the tasks
    --- never complete.
    local function mock_overseer()
        local created = {}
        package.loaded["overseer"] = {
            new_task = function(spec)
                created[#created + 1] = spec
                return {
                    id = #created, subscribe = function() end, start = function() end,
                    is_complete = function() return false end,
                }
            end,
        }
        return created
    end

    local function unit_of(profile, key)
        for _, pp in ipairs(profile:projects()) do
            if pp._config_unit and pp._project and pp._project.key == key then
                return pp._config_unit
            end
        end
        error("no unit for " .. key)
    end

    it("reruns configure for an already-configured unit", function()
        local ws, profile, r = make_core()
        root = r
        loomworks.get_workspace = function() return ws end
        local created = mock_overseer()

        local app = unit_of(profile, "App")
        app.state_value = "configured"
        assert.equals("configured", app:state())
        assert.equals("unconfigured", unit_of(profile, "Lib"):state())

        profile:configure()
        vim.wait(3000, function() return #created >= 2 end)

        assert.equals(2, #created, "one configure task per unit of the profile")
        local names = {}
        for _, spec in ipairs(created) do names[#names + 1] = spec.name or "?" end
        local joined = table.concat(names, " | ")
        assert.truthy(joined:find("App", 1, true), joined)
        assert.truthy(joined:find("Lib", 1, true), joined)
    end)
end)
