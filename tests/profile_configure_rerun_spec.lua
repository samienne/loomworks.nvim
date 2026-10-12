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
    local orig_create_op = loomworks.create_operation
    local root

    before_each(function() cpp.lookup_path = function() return nil end end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        loomworks.get_workspace = orig_get_ws
        loomworks.create_operation = orig_create_op
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
    it("still blocks a unit in unknown state", function()
        local ws, profile, r = make_core()
        root = r
        loomworks.get_workspace = function() return ws end
        loomworks.create_operation = function(...) return ws:create_operation(...) end
        local created = mock_overseer()
        local warnings = {}
        local orig_notify = vim.notify
        vim.notify = function(msg, level)
            if level == vim.log.levels.WARN then warnings[#warnings + 1] = msg end
        end

        local app = unit_of(profile, "App")
        app.state_value = "unknown"
        assert.equals("unknown", app:state())

        local ok, err = pcall(function()
            profile:configure()
            vim.wait(3000, function() return #created >= 1 end)
            vim.wait(100)
        end)
        vim.notify = orig_notify
        assert(ok, err)

        assert.equals(1, #created, "only the Lib configure is launched")
        assert.truthy((created[1].name or ""):find("Lib", 1, true), created[1].name)
        assert.truthy(table.concat(warnings, " | "):find("unknown state", 1, true),
            "user is told to clean or delete the unknown unit")
        for _, op in ipairs(profile:active_operations()) do
            assert.is_false(op:has_unit(app), "the blocked unit is not tracked")
        end
    end)

    it("completes only when its own configure tasks have completed", function()
        local ws, profile, r = make_core()
        root = r
        loomworks.get_workspace = function() return ws end
        loomworks.create_operation = function(...) return ws:create_operation(...) end

        -- Overseer mock whose tasks fire on_start when started and complete
        -- only when the test says so.
        local tasks = {}
        package.loaded["overseer"] = {
            new_task = function(spec)
                local subs = {}
                local t = { id = #tasks + 1, spec = spec, subs = subs }
                t.subscribe = function(_, ev, cb) subs[ev] = subs[ev] or {}; table.insert(subs[ev], cb) end
                t.start = function(self)
                    for _, cb in ipairs(subs.on_start or {}) do cb(self) end
                end
                t.is_complete = function() return false end
                t.finish = function(self, status)
                    for _, cb in ipairs(subs.on_complete or {}) do cb(self, status) end
                end
                tasks[#tasks + 1] = t
                return t
            end,
        }
        local function task_for(key)
            for _, t in ipairs(tasks) do
                if (t.spec.name or ""):find(key, 1, true) then return t end
            end
        end

        local app = unit_of(profile, "App")
        local lib = unit_of(profile, "Lib")
        app.state_value = "configured"
        lib.state_value = "configured"

        -- App's build dir is held by a running build: its configure waits
        -- for the lock (the queued callback is kept here).
        local app_waiting
        local orig_acquire = ws.acquire_build_dir_lock
        ws.acquire_build_dir_lock = function(self, dir, lock_type, fn)
            local rel = tostring(dir):lower():sub(#r + 1)
            if not app_waiting and rel:find("app", 1, true) then
                app_waiting = fn
                return
            end
            return orig_acquire(self, dir, lock_type, fn)
        end

        profile:configure()
        vim.wait(3000, function() return app_waiting ~= nil and task_for("Lib") ~= nil end)
        assert.is_not_nil(app_waiting, "App configure waits for the build-dir lock")
        local ops = profile:active_operations()
        assert.equals(1, #ops)
        local op = ops[1]

        -- The running build finishes: App reaches `built` before its
        -- configure has even started.
        app.state_value = "built"
        app:_notify()
        task_for("Lib"):finish("SUCCESS")
        vim.wait(100)
        assert.is_false(op.completed, "configure op must wait for App's own configure")

        -- Lock released: App's configure runs and completes.
        app_waiting()
        vim.wait(3000, function() return task_for("App") ~= nil end)
        assert.is_false(op.completed)
        task_for("App"):finish("SUCCESS")
        vim.wait(3000, function() return op.completed end)
        assert.is_true(op.completed)
        assert.is_true(op.success)
    end)

    it("completes when a counted unit turns unknown before its task launches", function()
        local ws, profile, r = make_core()
        root = r
        loomworks.get_workspace = function() return ws end
        local created_op
        local app
        -- Creating the operation emits events; a subscriber may move a unit
        -- to unknown before launch_tasks re-checks readiness. That unit was
        -- counted as pending but is never launched.
        loomworks.create_operation = function(...)
            created_op = ws:create_operation(...)
            app.state_value = "unknown"
            return created_op
        end
        local tasks = {}
        package.loaded["overseer"] = {
            new_task = function(spec)
                local subs = {}
                local t = { id = #tasks + 1, spec = spec }
                t.subscribe = function(_, ev, cb) subs[ev] = subs[ev] or {}; table.insert(subs[ev], cb) end
                t.start = function(self)
                    for _, cb in ipairs(subs.on_start or {}) do cb(self) end
                end
                t.is_complete = function() return false end
                t.finish = function(self, status)
                    for _, cb in ipairs(subs.on_complete or {}) do cb(self, status) end
                end
                tasks[#tasks + 1] = t
                return t
            end,
        }
        local orig_notify = vim.notify
        vim.notify = function() end

        app = unit_of(profile, "App")
        local lib = unit_of(profile, "Lib")
        app.state_value = "configured"
        lib.state_value = "configured"

        local ok, err = pcall(function()
            profile:configure()
            vim.wait(3000, function() return #tasks >= 1 end)
            vim.wait(100)
        end)
        vim.notify = orig_notify
        assert(ok, err)

        assert.is_not_nil(created_op)
        assert.equals(1, #tasks, "only Lib is launched")
        assert.truthy((tasks[1].spec.name or ""):find("Lib", 1, true), tasks[1].spec.name)
        tasks[1]:finish("SUCCESS")
        vim.wait(3000, function() return created_op.completed end)
        assert.is_true(created_op.completed, "the op must not hang on the never-launched unit")
        assert.is_false(created_op.success)
    end)
end)
