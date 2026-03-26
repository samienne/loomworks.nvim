local Profile = require("loomworks.profile").Profile
local h = require("tests.helpers")

describe("Profile", function()
    local function make_profile(overrides, core_overrides)
        -- Ensure mock workspace cache has skeleton entries so ProfileProject
        -- can resolve config_key from cache (required after variant-from-cache change).
        local default_cache = {
            configurations = {
                ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug" },
                ["Lib/Debug"] = { project_key = "Lib", config_key = "Debug", type = "cmake", variant = "Debug" },
            },
        }
        local ws_overrides = core_overrides or {}
        if not ws_overrides.cache and not ws_overrides.get_workspace then
            ws_overrides = vim.tbl_deep_extend("force", ws_overrides, { cache = default_cache })
        end
        local core = h.make_mock_core(ws_overrides)
        -- Register minimal mock projects so PP._project resolves
        local Project = require("loomworks.project")
        if not core._projects["App"] then
            core._projects["App"] = Project.new(core, "App", {
                type = "cmake", path = "App", status = "unconfigured",
                configurations = { Debug = { variant = "Debug" } }, cached_configurations = {},
            })
        end
        if not core._projects["Lib"] then
            core._projects["Lib"] = Project.new(core, "Lib", {
                type = "cmake", path = "Lib", status = "unconfigured",
                configurations = { Debug = { variant = "Debug" } }, cached_configurations = {},
            })
        end
        -- Ensure ConfigUnits exist for cached configurations so ProfileProject resolves them
        if core.cache and core.cache.configurations then
            for id, entry in pairs(core.cache.configurations) do
                h.ensure_config_unit_by_id(core, id, entry.project_key)
            end
        end
        local data = vim.tbl_deep_extend("force", {
            configuration_set = "debug",
            tools = nil,
            explicit = false,
            mappings = { App = "Debug", Lib = "Debug" },
            _cached_configurations = { "App/Debug", "Lib/Debug" },
        }, overrides or {})
        local profile = Profile.new(core, "debug", data)
        -- Populate profile_projects registry and Profile's direct lists
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                h.register_profile_project(core, profile, project_key, variant)
            end
            h.finalize_profile(profile)
        end
        return profile, core
    end

    describe("new", function()
        it("sets fields from data", function()
            local p = make_profile()
            assert.equals("debug", p.key)
            assert.equals("debug", p._configuration_set_name)
            assert.is_false(p.explicit)
        end)

        it("stores mappings", function()
            local p = make_profile()
            assert.equals("Debug", p.mappings.App)
            assert.equals("Debug", p.mappings.Lib)
        end)
    end)

    describe("project", function()
        it("returns ProfileProject for known project", function()
            local p = make_profile()
            local pp = p:project("App")
            assert.is_not_nil(pp)
            assert.equals("App", pp._init_project_key)
            assert.equals("Debug", pp:variant_name())
        end)

        it("returns nil for unknown project", function()
            local p = make_profile()
            assert.is_nil(p:project("NonExistent"))
        end)
    end)

    describe("projects", function()
        it("returns sorted ProfileProjects", function()
            local p = make_profile()
            local pps = p:projects()
            assert.equals(2, #pps)
            assert.equals("App", pps[1]._init_project_key)
            assert.equals("Lib", pps[2]._init_project_key)
        end)

        it("returns empty when no mappings", function()
            local core = h.make_mock_core()
            local p = Profile.new(core, "empty", {
                configuration_set = "debug",
            })
            assert.are.same({}, p:projects())
        end)
    end)

    describe("is_configured", function()
        it("returns false when no workspace", function()
            local p = make_profile()
            assert.is_false(p:is_configured())
        end)

        it("returns true when cached profile references configured config", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            profiles = {
                                debug = {
                                    configuration_set = "debug",
                                    configurations = { "App/Debug" },
                                },
                            },
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    variant = "Debug",
                                    type = "cmake",
                                    state = "configured",
                                },
                            },
                        },
                    }
                end,
            })
            assert.is_true(p:is_configured())
        end)

        it("returns false when cached profile exists but configs have no state", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            profiles = {
                                debug = {
                                    configuration_set = "debug",
                                    configurations = { "App/Debug" },
                                },
                            },
                            configurations = {
                                ["App/Debug"] = {
                                    project_key = "App",
                                    config_key = "Debug",
                                    type = "cmake",
                                    variant = "Debug", -- skeleton, no state
                                },
                            },
                        },
                    }
                end,
            })
            assert.is_false(p:is_configured())
        end)

        it("returns false when no cached profile matches", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            profiles = {
                                release = {
                                    configuration_set = "release",
                                    configurations = { "App/Release" },
                                },
                            },
                            configurations = {
                                ["App/Release"] = {
                                    project_key = "App",
                                    config_key = "Release",
                                    variant = "Release",
                                    type = "cmake",
                                    state = "configured",
                                },
                            },
                        },
                    }
                end,
            })
            assert.is_false(p:is_configured())
        end)
    end)

    describe("is_running", function()
        it("returns false when nothing running", function()
            local p = make_profile()
            assert.is_false(p:is_running())
        end)

        it("returns true when profile has running action", function()
            local p, core = make_profile()
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "build")
            assert.is_true(p:is_running())
        end)
    end)

    describe("status (aggregate)", function()
        it("returns empty for profile with no mappings", function()
            local core = h.make_mock_core()
            local p = Profile.new(core, "empty", { configuration_set = "debug" })
            local label, hl = p:status()
            assert.equals("empty", label)
            assert.equals("Comment", hl)
        end)

        it("returns unconfigured when all unconfigured", function()
            local p = make_profile()
            local label, hl = p:status()
            assert.equals("unconfigured", label)
            assert.equals("Comment", hl)
        end)

        it("returns built when all built", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            configurations = {
                                ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug", state = "built" },
                                ["Lib/Debug"] = { project_key = "Lib", config_key = "Debug", type = "cmake", variant = "Debug", state = "built" },
                            },
                        },
                    }
                end,
            })
            local label, hl = p:status()
            assert.equals("built", label)
            assert.equals("DiagnosticOk", hl)
        end)

        it("returns mixed status label", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            configurations = {
                                ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug", state = "built" },
                            },
                        },
                    }
                end,
            })
            local label, _ = p:status()
            -- App is built, Lib is unconfigured => mixed
            assert.matches("built", label)
            assert.matches("unconfigured", label)
        end)

        it("shows failure info", function()
            local p = make_profile(nil, {
                get_workspace = function()
                    return {
                        cache = {
                            configurations = {
                                ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug", state = "failed_build" },
                                ["Lib/Debug"] = { project_key = "Lib", config_key = "Debug", type = "cmake", variant = "Debug", state = "built" },
                            },
                        },
                    }
                end,
            })
            local label, hl = p:status()
            assert.matches("failed", label)
            assert.equals("DiagnosticError", hl)
        end)

        it("shows running status with number first", function()
            local p, core = make_profile()
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "build")
            local label, hl = p:status()
            assert.matches("1 building", label)
            assert.equals("DiagnosticWarn", hl)
        end)

        it("shows deleting status with number first", function()
            local p, core = make_profile()
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:mark_deleting(true)
            local label, hl = p:status()
            assert.matches("1/2 deleting", label)
            assert.equals("DiagnosticError", hl)
        end)
    end)

    describe("plan_deletion", function()
        it("returns empty when no mappings", function()
            local core = h.make_mock_core()
            local p = Profile.new(core, "empty", { configuration_set = "debug" })
            local plan = p:plan_deletion()
            assert.are.same({}, plan.items)
        end)

        it("returns items for each mapped project", function()
            local p, core = make_profile()
            -- Register as the only profile so other_refs is empty
            core._profiles = { debug = p }
            local plan = p:plan_deletion()
            assert.equals(2, #plan.items)
            -- Items sorted by project key, keys read from unit._project
            local keys = {}
            for _, item in ipairs(plan.items) do
                keys[#keys + 1] = item.unit and item.unit._project and item.unit._project.key
            end
            table.sort(keys)
            assert.equals("App", keys[1])
            assert.equals("Lib", keys[2])
        end)
    end)

    describe("activate / deactivate", function()
        it("activate writes user.json and remerges", function()
            local saved_user = nil
            local remerged = false
            local ws = {
                root = "/root",
                user = { _meta = { version = 1 }, active_profile = nil },
            }
            local p = make_profile(nil, {
                get_workspace = function() return ws end,
                remerge = function() remerged = true end,
                _deps = {
                    clock = function() return 0 end,
                    events = { emit = function() end },
                    user = { save = function(root, data) saved_user = data return true end },
                },
            })
            p:activate()
            assert.equals("debug", ws.user.active_profile)
            assert.equals("debug", saved_user.active_profile)
            assert.is_true(remerged)
        end)

        it("activate is no-op without workspace", function()
            local p = make_profile(nil, {
                get_workspace = function() return nil end,
            })
            p:activate() -- should not error
        end)

        it("deactivate clears active_profile and remerges", function()
            local saved_user = nil
            local remerged = false
            local ws = {
                root = "/root",
                user = { _meta = { version = 1 }, active_profile = "debug" },
            }
            local p = make_profile(nil, {
                get_workspace = function() return ws end,
                remerge = function() remerged = true end,
                _deps = {
                    clock = function() return 0 end,
                    events = { emit = function() end },
                    user = { save = function(root, data) saved_user = data return true end },
                },
            })
            p:deactivate()
            assert.is_nil(ws.user.active_profile)
            assert.is_nil(saved_user.active_profile)
            assert.is_true(remerged)
        end)

        it("deactivate is no-op when not active", function()
            local save_called = false
            local ws = {
                root = "/root",
                user = { _meta = { version = 1 }, active_profile = "release" },
            }
            local p = make_profile(nil, {
                get_workspace = function() return ws end,
                _deps = {
                    clock = function() return 0 end,
                    events = { emit = function() end },
                    user = { save = function() save_called = true return true end },
                },
            })
            p:deactivate()
            assert.equals("release", ws.user.active_profile)
            assert.is_false(save_called)
        end)

        it("deactivate is no-op without workspace", function()
            local p = make_profile(nil, {
                get_workspace = function() return nil end,
            })
            p:deactivate() -- should not error
        end)
    end)
end)

describe("ProfileProject", function()
    local function make_pp(tool_key, core_overrides)
        -- Provide workspace with config so ProfileProject.new can check project type
        local default_ws = {
            config = {
                projects = {
                    App = { type = "cmake", path = "App", type_config = {} },
                },
            },
            cache = { configurations = {} },
        }
        local merged = vim.tbl_deep_extend("force", {
            get_workspace = function() return default_ws end,
        }, core_overrides or {})
        local core = h.make_mock_core(merged)
        -- Add skeleton cache entry so ProfileProject can resolve config_key
        core.cache.configurations["App/Debug"] = {
            project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug",
        }
        -- Add a Project object so ProfileProject can resolve it
        local Project = require("loomworks.project")
        core._projects["App"] = Project.new(core, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = {}, cached_configurations = {},
        })
        -- Ensure ConfigUnit exists so ProfileProject resolves it
        h.ensure_config_unit_by_id(core, "App/Debug", "App")
        local tools = tool_key and { cmake = { key = tool_key } } or nil
        local data = {
            configuration_set = "debug",
            tools = tools,
            mappings = { App = "Debug" },
            _cached_configurations = { "App/Debug" },
        }
        local profile = Profile.new(core, "debug", data)
        -- Populate profile_projects registry and Profile's direct lists
        if profile.mappings then
            for project_key, variant in pairs(profile.mappings) do
                h.register_profile_project(core, profile, project_key, variant)
            end
            h.finalize_profile(profile)
        end
        return profile:project("App"), core
    end

    describe("status", function()
        it("returns unconfigured by default", function()
            local pp = make_pp(nil)
            assert.equals("unconfigured", pp:status())
        end)

        it("returns deleting when unit is marked deleting", function()
            local pp, core = make_pp(nil)
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:mark_deleting(true)
            assert.equals("deleting", pp:status())
        end)

        it("returns configuring when configure task is running", function()
            local pp, core = make_pp(nil)
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "configure")
            assert.equals("configuring", pp:status())
        end)

        it("returns building when build task is running", function()
            local pp, core = make_pp(nil)
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "build")
            assert.equals("building", pp:status())
        end)
    end)

    describe("running_action", function()
        it("returns nil when nothing running", function()
            local pp = make_pp(nil)
            assert.is_nil(pp:running_action())
        end)

        it("returns the action from the ConfigUnit", function()
            local pp, core = make_pp(nil)
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "build")
            assert.equals("build", pp:running_action())
        end)

        it("shares running state across profiles via ConfigUnit", function()
            -- Two profiles referencing the same (project_key, config_key)
            -- should see the same running state
            local core = h.make_mock_core({
                config = {
                    projects = {
                        App = { type = "cmake", path = "App", type_config = {} },
                    },
                },
                cache = {
                    configurations = {
                        ["App/Debug"] = { project_key = "App", config_key = "Debug", type = "cmake", variant = "Debug" },
                    },
                },
            })
            local Project = require("loomworks.project")
            core._projects["App"] = Project.new(core, "App", {
                type = "cmake", path = "App", status = "unconfigured",
                configurations = {}, cached_configurations = {},
            })
            -- Ensure ConfigUnit exists before ProfileProject construction
            h.ensure_config_unit_by_id(core, "App/Debug", "App")
            local Profile = require("loomworks.profile").Profile
            local p1 = Profile.new(core, "debug:ninja-gcc", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
                _cached_configurations = { "App/Debug" },
            })
            local p2 = Profile.new(core, "debug:ninja-clang", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
                _cached_configurations = { "App/Debug" },
            })
            -- Populate profile_projects registry and Profile's direct lists
            for _, p in ipairs({ p1, p2 }) do
                for pk, v in pairs(p.mappings) do
                    h.register_profile_project(core, p, pk, v)
                end
                h.finalize_profile(p)
            end
            -- Start a task on the shared unit
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:register_task(1, "build")
            -- Both profiles see it
            assert.equals("build", p1:project("App"):running_action())
            assert.equals("build", p2:project("App"):running_action())
        end)
    end)

    describe("is_deleting", function()
        it("returns false by default", function()
            local pp = make_pp(nil)
            assert.is_false(pp:is_deleting())
        end)

        it("returns true when unit is marked deleting", function()
            local pp, core = make_pp(nil)
            local unit = core:ensure_config_unit(core._projects["App"], h.get_or_create_config(core._projects["App"], "Debug"), nil)
            unit:mark_deleting(true)
            assert.is_true(pp:is_deleting())
        end)
    end)

    -- cached_state() and build_dir() delegate to ConfigUnit.cached_state() —
    -- covered by config_unit_spec.lua cached_state tests.

end)
