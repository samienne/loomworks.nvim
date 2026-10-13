-- Test lw.buf_status as lualine uses it: init.lua reads the two views
-- (spec §19.13 "Two sources, one shape") through loomworks.views; here the
-- views are built in-process from a test Core with the same builder
-- (Core:view_header / Core:view_projects_index), and the buffer path comes
-- from the test's `buf_name`.

local Core = require("loomworks.core")
local views = require("loomworks.views")
local h = require("tests.helpers")

local function make_core(config_overrides, user_overrides, cache_overrides, dep_overrides)
    local files = {
        ["loomworks.json"] = h.make_config_json(config_overrides),
    }
    if user_overrides then
        files["loomworks.user.json"] = h.make_user_json(user_overrides)
    end
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end
    local deps = h.make_test_deps(files, dep_overrides)
    local core = Core.new(deps)
    return core, deps
end

--- lw.buf_status over the in-process views of `core` (mirrors init.lua).
local function buf_status(core, bufnr)
    local header = core:view_header()
    if not header or header.state ~= "loaded" then return nil end
    return views.status_of(header, core:view_projects_index(), core._deps.buf_name(bufnr or 0))
end

describe("buf_status", function()
    it("returns nil without workspace", function()
        local core = make_core()
        -- no setup call — core has no workspace
        local result = buf_status(core, 0)
        assert.is_nil(result)
    end)

    it("returns nil when buffer not in any project", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, nil, nil, {
            buf_name = function() return "/other/path/file.cpp" end,
        })
        core:setup({ root = "/root" })
        local result = buf_status(core, 0)
        assert.is_nil(result)
    end)

    it("returns project info for matching buffer", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, {
            active_profile = "debug",
            profiles = {
                debug = { configuration_set = "debug" },
            },
        }, {
            configurations = {
                ["App/Debug"] = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    type = "cmake",
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("debug", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("App", result.project)
        assert.equals("Debug", result.configuration)
    end)

    it("includes tool_key when profile has one", function()
        local detected_tools = {
            cmake = {
                { tool_data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                    tool_key = "ninja-gcc-12", tool_label = "Ninja + GCC 12" },
            },
        }
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, {
            active_profile = "debug:ninja-gcc-12",
            profiles = {
                ["debug:ninja-gcc-12"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" } } },
                },
            },
        }, {
            build_dirs = {
                ["build/App/ninja-gcc-12/Debug"] = {
                    project_key = "App",
                    config_key = "Debug:ninja-gcc-12",
                    variant = "Debug",
                    type = "cmake",
                    state = "configured",
                    tool_key = "ninja-gcc-12",
                    tool_data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
            modules = {
                get = function(mod_type)
                    if mod_type ~= "cmake" then return nil end
                    return {
                        id = "cmake",
                        has_keyed_tools = true,
                        validate = function() return { valid = true, warnings = {} } end,
                        info = function() return { configurations = {} } end,
                        detect_tools_async = function(callback) callback({
                            { tool_data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" } },
                        }) end,
                        tool_key = function(td) return td.id end,
                        tool_label = function(td) return td.display or td.id end,
                        tools_match = function(a, b)
                            if a == nil and b == nil then return true end
                            if a == nil or b == nil then return false end
                            return vim.deep_equal(a, b)
                        end,
                    }
                end,
            },
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("debug:ninja-gcc-12", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("ninja-gcc-12", result.tool_key)
    end)

    it("returns status from config unit", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, {
            active_profile = "debug",
            profiles = {
                debug = { configuration_set = "debug" },
            },
        }, {
            configurations = {
                ["App/Debug"] = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    type = "cmake",
                    state = "built",
                    build_dir = "/root/.nvim/build/App/Debug",
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("App", result.project)
        -- The merged status comes through the ConfigUnit
        assert.equals("Debug", result.configuration)
    end)

    it("returns nil set_name when profile_key is nil", function()
        -- When there is an active set but no profile key (e.g. projects exist
        -- but no profile is activated), set_name should be nil.
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, nil, nil, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        -- With no active profile, active_set.name is nil, so buf_status
        -- should still return project info but with nil profile/set_name.
        if result then
            assert.is_nil(result.profile_key)
            assert.is_nil(result.set_name)
            assert.equals("App", result.project)
        end
    end)

    it("returns nil tool_key for non-cmake projects", function()
        local core = make_core({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { debug = { Frontend = "debug" } },
        }, { active_profile = "debug" }, {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    configurations = { "Frontend/debug" },
                },
            },
            configurations = {
                ["Frontend/debug"] = {
                    project_key = "Frontend",
                    config_key = "debug",
                    variant = "debug",
                    type = "ets",
                },
            },
        }, {
            buf_name = function() return "/root/Frontend/src/main.ets" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("Frontend", result.project)
        assert.is_nil(result.tool_key)
    end)

    it("a project at /root/App does not claim a buffer in /root/AppX (separator boundary)", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, {
            active_profile = "debug",
            profiles = { debug = { configuration_set = "debug" } },
        }, nil, {
            buf_name = function() return "/root/AppX/src/main.cpp" end,
        })
        core:setup({ root = "/root" })
        assert.is_nil(buf_status(core, 0))
    end)
end)

describe("loomworks.views", function()
    local function rec(key, abs, active)
        return { key = key, label = key, type = "cmake", path = key, abs_path = abs, active = active }
    end

    it("matches the longest prefix on a separator boundary", function()
        local idx = { projects = { rec("a", "/w/a"), rec("ab", "/w/a/b"), rec("foo", "/w/foo") } }
        assert.equals("ab", views.match(idx, "/w/a/b/x.c").key)
        assert.equals("a", views.match(idx, "/w/a/bc/x.c").key)
        assert.equals("a", views.match(idx, "/w/a").key)
        assert.is_nil(views.match(idx, "/w/foobar/x.c"))
        assert.is_nil(views.match(idx, ""))
        assert.is_nil(views.match(nil, "/w/a/x.c"))
    end)

    it("status_of is nil unless the header is loaded", function()
        local idx = { projects = { rec("a", "/w/a", { configuration = "Debug", state = "built" }) } }
        assert.is_nil(views.status_of({ root = "/w", state = "unloaded" }, { projects = {} }, "/w/a/x.c"))
        assert.is_nil(views.status_of({ root = "/w", state = "error", error = "x" }, idx, "/w/a/x.c"))
        local st = views.status_of({ root = "/w", state = "loaded", active_profile = "p", config_set = "s",
            diagnostics = "warn" }, idx, "/w/a/x.c")
        assert.same({ profile_key = "p", set_name = "s", project = "a", configuration = "Debug",
            status = "built", profile_state = "built", diagnostic_severity = "warn" }, st)
    end)

    it("profile_state aggregates the mapped projects", function()
        local function idx(...)
            local out = {}
            for i, s in ipairs({ ... }) do out[i] = rec("p" .. i, "/w/p" .. i, { configuration = "D", state = s }) end
            out[#out + 1] = rec("unmapped", "/w/u")
            return { projects = out }
        end
        assert.equals("building", views.profile_state(idx("built", "building")))
        assert.equals("failed_build", views.profile_state(idx("built", "build_failed")))
        assert.equals("built", views.profile_state(idx("built", "built")))
        assert.equals("configured", views.profile_state(idx("built", "configured")))
        assert.equals("unconfigured", views.profile_state(idx("unconfigured")))
        assert.equals("mixed", views.profile_state(idx("built", "unconfigured")))
        assert.is_nil(views.profile_state({ projects = { rec("u", "/w/u") } }))
    end)

    it("serves the daemon's table while set, the builder's otherwise", function()
        local owner = {}
        views.set_builder("projects", function() return { projects = { rec("built", "/w/b") } } end)
        assert.equals("in-process", views.source("projects"))
        assert.equals("built", views.projects_index().projects[1].key)
        views.set(owner, "projects", { projects = {} })
        assert.equals("daemon", views.source("projects"))
        assert.same({}, views.projects_index().projects)
        views.clear({}, "projects") -- another owner: kept
        assert.equals("daemon", views.source("projects"))
        views.clear(owner)
        assert.equals("in-process", views.source("projects"))
        -- Restore init.lua's builder.
        local core = require("loomworks")._core()
        views.set_builder("projects", function() return core:view_projects_index() end)
    end)
end)
