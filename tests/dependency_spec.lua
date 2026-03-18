--- Tests for dependency resolution and build ordering.

local dependency = require("loomworks.dependency")
local h = require("tests.helpers")
local Profile = require("loomworks.profile").Profile
local ProfileProject = require("loomworks.profile").ProfileProject
local Project = require("loomworks.project")

--- Create a mock project with depends_on references.
local function make_project(core, key, deps)
    local p = Project.new(core, key, {
        type = "cmake", path = key, status = "unconfigured",
        configurations = {}, cached_configurations = {},
        depends_on = deps and vim.tbl_map(function(k) return k end, deps) or nil,
    })
    return p
end

describe("dependency", function()
    describe("toposort", function()
        it("returns alphabetical order when no dependencies", function()
            local core = h.make_mock_core()
            local pA = make_project(core, "App", nil)
            local pB = make_project(core, "Backend", nil)
            local pC = make_project(core, "Core", nil)
            core._projects = { App = pA, Backend = pB, Core = pC }

            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug", Backend = "Debug", Core = "Debug" },
            })
            for pk, v in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. pk
                core._profile_projects[reg_key] = ProfileProject.new(
                    core, profile, pk, v)
            end

            local pps = profile:projects()
            assert.equals(3, #pps)
            assert.equals("App", pps[1].project_key)
            assert.equals("Backend", pps[2].project_key)
            assert.equals("Core", pps[3].project_key)
        end)

        it("puts dependencies before dependents", function()
            local core = h.make_mock_core()
            local pCore = make_project(core, "Core", nil)
            local pApp = make_project(core, "App", nil)
            core._projects = { App = pApp, Core = pCore }
            -- App depends on Core
            pApp.depends_on = { pCore }

            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug", Core = "Debug" },
            })
            for pk, v in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. pk
                core._profile_projects[reg_key] = ProfileProject.new(
                    core, profile, pk, v)
            end

            local pps = profile:projects()
            assert.equals(2, #pps)
            assert.equals("Core", pps[1].project_key)
            assert.equals("App", pps[2].project_key)
        end)

        it("handles diamond dependencies", function()
            local core = h.make_mock_core()
            local pBase = make_project(core, "Base", nil)
            local pLeft = make_project(core, "Left", nil)
            local pRight = make_project(core, "Right", nil)
            local pTop = make_project(core, "Top", nil)
            core._projects = { Base = pBase, Left = pLeft, Right = pRight, Top = pTop }
            pLeft.depends_on = { pBase }
            pRight.depends_on = { pBase }
            pTop.depends_on = { pLeft, pRight }

            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { Base = "Debug", Left = "Debug", Right = "Debug", Top = "Debug" },
            })
            for pk, v in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. pk
                core._profile_projects[reg_key] = ProfileProject.new(
                    core, profile, pk, v)
            end

            local pps = profile:projects()
            assert.equals(4, #pps)
            assert.equals("Base", pps[1].project_key)
            -- Left and Right can be in either order, but both before Top
            local middle = { pps[2].project_key, pps[3].project_key }
            table.sort(middle)
            assert.equals("Left", middle[1])
            assert.equals("Right", middle[2])
            assert.equals("Top", pps[4].project_key)
        end)

        it("detects circular dependencies", function()
            local core = h.make_mock_core()
            local pA = make_project(core, "A", nil)
            local pB = make_project(core, "B", nil)
            core._projects = { A = pA, B = pB }
            pA.depends_on = { pB }
            pB.depends_on = { pA }

            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { A = "Debug", B = "Debug" },
            })
            for pk, v in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. pk
                core._profile_projects[reg_key] = ProfileProject.new(
                    core, profile, pk, v)
            end

            -- Should still return all projects (falls back to alphabetical)
            local pps = profile:projects()
            assert.equals(2, #pps)
        end)

        it("ignores dependencies on projects not in the profile", function()
            local core = h.make_mock_core()
            local pApp = make_project(core, "App", nil)
            local pExternal = make_project(core, "External", nil)
            core._projects = { App = pApp, External = pExternal }
            pApp.depends_on = { pExternal }

            -- Only App is in the profile, not External
            local profile = Profile.new(core, "debug", {
                configuration_set = "debug",
                mappings = { App = "Debug" },
            })
            for pk, v in pairs(profile.mappings) do
                local reg_key = profile.key .. "\0" .. pk
                core._profile_projects[reg_key] = ProfileProject.new(
                    core, profile, pk, v)
            end

            local pps = profile:projects()
            assert.equals(1, #pps)
            assert.equals("App", pps[1].project_key)
        end)
    end)
end)
