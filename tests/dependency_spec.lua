--- Tests for dependency resolution and build ordering.

local dependency = require("loomworks.dependency")
local h = require("tests.helpers")
local Profile = require("loomworks.profile").Profile
local ConfigurationSet = require("loomworks.configuration_set")
local Project = require("loomworks.project")

--- Create a mock project with depends_on references.
local function make_project(core, key, deps)
    local p = Project.new(core, key, {
        type = "cmake", path = key, status = "unconfigured",
        configurations = { Debug = { variant = "Debug" } }, cached_configurations = {},
        depends_on = deps and vim.tbl_map(function(k) return k end, deps) or nil,
    })
    return p
end

--- Create a ConfigurationSet from projects dict and variant, then create Profile with _config_set_ref.
--- @param core table mock workspace
--- @param projects table<string, loomworks.Project> project dict
--- @param variant string configuration variant
--- @return loomworks.Profile
local function make_set_profile(core, projects, variant)
    local cs_mappings = {}
    local raw_mappings = {}
    for key, proj in pairs(projects) do
        cs_mappings[proj] = h.get_or_create_config(proj, variant)
        raw_mappings[key] = variant
    end
    local cs = ConfigurationSet.new(core, "debug", cs_mappings)
    core._config_sets[#core._config_sets + 1] = cs
    local profile = Profile.new(core, {
        configuration_set = "debug",
        _config_set_ref = cs,
    })
    for pk, v in pairs(profile.mappings) do
        h.register_profile_project(core, profile, pk, v)
    end
    h.finalize_profile(profile)
    return profile
end

describe("dependency", function()
    describe("toposort", function()
        it("returns alphabetical order when no dependencies", function()
            local core = h.make_mock_core()
            local pA = make_project(core, "App", nil)
            local pB = make_project(core, "Backend", nil)
            local pC = make_project(core, "Core", nil)
            core._projects = { pA, pB, pC }

            local profile = make_set_profile(core, { App = pA, Backend = pB, Core = pC }, "Debug")

            local pps = profile:projects()
            assert.equals(3, #pps)
            assert.equals("App", pps[1]._init_project_key)
            assert.equals("Backend", pps[2]._init_project_key)
            assert.equals("Core", pps[3]._init_project_key)
        end)

        it("puts dependencies before dependents", function()
            local core = h.make_mock_core()
            local pCore = make_project(core, "Core", nil)
            local pApp = make_project(core, "App", nil)
            core._projects = { pApp, pCore }
            -- App depends on Core
            pApp.depends_on = { pCore }

            local profile = make_set_profile(core, { App = pApp, Core = pCore }, "Debug")

            local pps = profile:projects()
            assert.equals(2, #pps)
            assert.equals("Core", pps[1]._init_project_key)
            assert.equals("App", pps[2]._init_project_key)
        end)

        it("handles diamond dependencies", function()
            local core = h.make_mock_core()
            local pBase = make_project(core, "Base", nil)
            local pLeft = make_project(core, "Left", nil)
            local pRight = make_project(core, "Right", nil)
            local pTop = make_project(core, "Top", nil)
            core._projects = { pBase, pLeft, pRight, pTop }
            pLeft.depends_on = { pBase }
            pRight.depends_on = { pBase }
            pTop.depends_on = { pLeft, pRight }

            local profile = make_set_profile(core, { Base = pBase, Left = pLeft, Right = pRight, Top = pTop }, "Debug")

            local pps = profile:projects()
            assert.equals(4, #pps)
            assert.equals("Base", pps[1]._init_project_key)
            -- Left and Right can be in either order, but both before Top
            local middle = { pps[2]._init_project_key, pps[3]._init_project_key }
            table.sort(middle)
            assert.equals("Left", middle[1])
            assert.equals("Right", middle[2])
            assert.equals("Top", pps[4]._init_project_key)
        end)

        it("detects circular dependencies", function()
            local core = h.make_mock_core()
            local pA = make_project(core, "A", nil)
            local pB = make_project(core, "B", nil)
            core._projects = { pA, pB }
            pA.depends_on = { pB }
            pB.depends_on = { pA }

            local profile = make_set_profile(core, { A = pA, B = pB }, "Debug")

            -- Should still return all projects (falls back to alphabetical)
            local pps = profile:projects()
            assert.equals(2, #pps)
        end)

        it("ignores dependencies on projects not in the profile", function()
            local core = h.make_mock_core()
            local pApp = make_project(core, "App", nil)
            local pExternal = make_project(core, "External", nil)
            core._projects = { pApp, pExternal }
            pApp.depends_on = { pExternal }

            -- Only App is in the profile, not External
            local profile = make_set_profile(core, { App = pApp }, "Debug")

            local pps = profile:projects()
            assert.equals(1, #pps)
            assert.equals("App", pps[1]._init_project_key)
        end)
    end)
end)
