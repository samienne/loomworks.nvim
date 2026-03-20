local config_editor = require("loomworks.config_editor")
local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop

--- Create a temp directory for test use.
--- @return string path
local function make_tmpdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return path
end

--- Write raw content to a file.
--- @param path string
--- @param content string
local function write_raw(path, content)
    local fd = uv.fs_open(path, "w", 438)
    uv.fs_write(fd, content, 0)
    uv.fs_close(fd)
end

describe("config_editor", function()
    local tmpdirs = {}

    local function tmpdir()
        local d = make_tmpdir()
        tmpdirs[#tmpdirs + 1] = d
        return d
    end

    after_each(function()
        for _, d in ipairs(tmpdirs) do
            io_mod.rm_rf(d)
        end
        tmpdirs = {}
    end)

    -- -----------------------------------------------------------------
    -- create_workspace
    -- -----------------------------------------------------------------
    describe("create_workspace", function()
        it("creates loomworks.json with name and empty projects", function()
            local dir = tmpdir()

            local ok, err = config_editor.create_workspace(dir, "TestWorkspace")
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_not_nil(data)
            assert.equals("TestWorkspace", data.name)
            assert.is_not_nil(data.projects)
            assert.is_nil(next(data.projects))
        end)

        it("defaults name to directory basename", function()
            local dir = tmpdir()

            local ok = config_editor.create_workspace(dir)
            assert.is_true(ok)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            local expected = dir:match("([^/]+)$")
            assert.equals(expected, data.name)
        end)

        it("fails if loomworks.json already exists", function()
            local dir = tmpdir()
            write_raw(dir .. "/loomworks.json", "{}")

            local ok, err = config_editor.create_workspace(dir)
            assert.is_false(ok)
            assert.is_not_nil(err)
            assert.truthy(err:match("already exists"))
        end)
    end)

    -- -----------------------------------------------------------------
    -- add_project
    -- -----------------------------------------------------------------
    describe("add_project", function()
        it("adds a project entry to loomworks.json", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {},
            })

            local ok, err = config_editor.add_project(dir, "App", "cmake")
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_not_nil(data.projects.App)
            assert.is_not_nil(data.projects.App.cmake)

            -- Verify the type config encodes as {} not []
            local raw = io_mod.read_file(dir .. "/loomworks.json")
            assert.is_nil(raw:find('"cmake": %['), "type config should not encode as []")
            assert.is_not_nil(raw:find('"cmake"'), "type config key should exist")
        end)

        it("includes path field when path differs from key", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {},
            })

            local ok = config_editor.add_project(dir, "MyLib", "cmake", "libs/MyLib")
            assert.is_true(ok)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.equals("libs/MyLib", data.projects.MyLib.path)
        end)

        it("omits path field when path equals key", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {},
            })

            local ok = config_editor.add_project(dir, "App", "cmake", "App")
            assert.is_true(ok)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.projects.App.path)
        end)

        it("fails on duplicate project key", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
            })

            local ok, err = config_editor.add_project(dir, "App", "typescript")
            assert.is_false(ok)
            assert.truthy(err:match("already exists"))
        end)

        it("preserves existing projects", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { Existing = { cmake = {} } },
            })

            config_editor.add_project(dir, "NewProj", "typescript")

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_not_nil(data.projects.Existing)
            assert.is_not_nil(data.projects.Existing.cmake)
            assert.is_not_nil(data.projects.NewProj)
            assert.is_not_nil(data.projects.NewProj.typescript)
        end)

        it("fails when loomworks.json does not exist", function()
            local dir = tmpdir()

            local ok, err = config_editor.add_project(dir, "App", "cmake")
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)

    -- -----------------------------------------------------------------
    -- remove_project
    -- -----------------------------------------------------------------
    describe("remove_project", function()
        it("removes a project from loomworks.json", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                    Lib = { typescript = {} },
                },
            })

            local ok, err = config_editor.remove_project(dir, "App")
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.projects.App)
            assert.is_not_nil(data.projects.Lib)
        end)

        it("removes project from configuration_sets", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
                configuration_sets = {
                    debug = { App = "Debug", Lib = "Debug" },
                    release = { App = "Release", Lib = "Release" },
                },
            })

            config_editor.remove_project(dir, "App")

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.configuration_sets.debug.App)
            assert.equals("Debug", data.configuration_sets.debug.Lib)
            assert.is_nil(data.configuration_sets.release.App)
            assert.equals("Release", data.configuration_sets.release.Lib)
        end)

        it("removes empty configuration_sets", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                },
                configuration_sets = {
                    debug = { App = "Debug" },
                },
            })

            config_editor.remove_project(dir, "App")

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.configuration_sets)
        end)

        it("fails for non-existent project", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
            })

            local ok, err = config_editor.remove_project(dir, "DoesNotExist")
            assert.is_false(ok)
            assert.truthy(err:match("not found"))
        end)

        it("fails when loomworks.json does not exist", function()
            local dir = tmpdir()

            local ok, err = config_editor.remove_project(dir, "App")
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)

        it("handles projects with no configuration_sets", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                },
            })

            local ok, err = config_editor.remove_project(dir, "App")
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.projects.App)
        end)

        it("preserves other fields in loomworks.json", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "MyWorkspace",
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
                configuration_sets = {
                    debug = { App = "Debug", Lib = "Debug" },
                },
            })

            config_editor.remove_project(dir, "App")

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.equals("MyWorkspace", data.name)
            assert.is_not_nil(data.projects.Lib)
        end)
    end)

    -- -----------------------------------------------------------------
    -- add_configuration_set
    -- -----------------------------------------------------------------
    describe("add_configuration_set", function()
        it("adds a configuration set to loomworks.json", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
            })

            local ok, err = config_editor.add_configuration_set(dir, "Debug", {
                App = "Debug",
                Lib = "Debug",
            })
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_not_nil(data.configuration_sets)
            assert.is_not_nil(data.configuration_sets.Debug)
            assert.equals("Debug", data.configuration_sets.Debug.App)
            assert.equals("Debug", data.configuration_sets.Debug.Lib)
        end)

        it("fails on duplicate set name", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            })

            local ok, err = config_editor.add_configuration_set(dir, "Debug", { App = "Debug" })
            assert.is_false(ok)
            assert.truthy(err:match("already exists"))
        end)

        it("preserves existing configuration sets", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            })

            config_editor.add_configuration_set(dir, "Release", { App = "Release" })

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.equals("Debug", data.configuration_sets.Debug.App)
            assert.equals("Release", data.configuration_sets.Release.App)
        end)

        it("fails when loomworks.json does not exist", function()
            local dir = tmpdir()

            local ok, err = config_editor.add_configuration_set(dir, "Debug", { App = "Debug" })
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)

    -- -----------------------------------------------------------------
    -- remove_configuration_set
    -- -----------------------------------------------------------------
    describe("remove_configuration_set", function()
        it("removes a configuration set", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug = { App = "Debug" },
                    Release = { App = "Release" },
                },
            })

            local ok, err = config_editor.remove_configuration_set(dir, "Debug")
            assert.is_true(ok)
            assert.is_nil(err)

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.configuration_sets.Debug)
            assert.is_not_nil(data.configuration_sets.Release)
        end)

        it("removes configuration_sets key when last set removed", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            })

            config_editor.remove_configuration_set(dir, "Debug")

            local data = io_mod.read_json(dir .. "/loomworks.json")
            assert.is_nil(data.configuration_sets)
        end)

        it("fails for non-existent set", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug = { App = "Debug" },
                },
            })

            local ok, err = config_editor.remove_configuration_set(dir, "DoesNotExist")
            assert.is_false(ok)
            assert.truthy(err:match("not found"))
        end)

        it("fails when loomworks.json does not exist", function()
            local dir = tmpdir()

            local ok, err = config_editor.remove_configuration_set(dir, "Debug")
            assert.is_false(ok)
            assert.is_not_nil(err)
        end)
    end)

    -- -----------------------------------------------------------------
    -- generate_default_config_sets
    -- -----------------------------------------------------------------
    describe("generate_default_config_sets", function()
        it("generates Debug and Release for cmake projects", function()
            local dir = tmpdir()
            -- Create project directories with CMakeLists.txt
            vim.fn.mkdir(dir .. "/App", "p")
            write_raw(dir .. "/App/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")
            vim.fn.mkdir(dir .. "/Lib", "p")
            write_raw(dir .. "/Lib/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")

            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                    Lib = { cmake = {} },
                },
            })

            local sets, err = config_editor.generate_default_config_sets(dir)
            assert.is_nil(err)
            assert.is_not_nil(sets)
            assert.is_not_nil(sets.Debug)
            assert.equals("Debug", sets.Debug.App)
            assert.equals("Debug", sets.Debug.Lib)
            assert.is_not_nil(sets.Release)
            assert.equals("Release", sets.Release.App)
            assert.equals("Release", sets.Release.Lib)
        end)

        it("generates Default for single-config projects", function()
            local dir = tmpdir()
            -- Create a typescript project with a single default config
            vim.fn.mkdir(dir .. "/Frontend", "p")
            write_raw(dir .. "/Frontend/tsconfig.json", "{}")
            write_raw(dir .. "/Frontend/package.json", vim.json.encode({
                devDependencies = { typescript = "^5.0.0" },
            }))

            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    Frontend = { typescript = {} },
                },
            })

            local sets, err = config_editor.generate_default_config_sets(dir)
            assert.is_nil(err)
            assert.is_not_nil(sets)
            -- Single config "default" matches any variant via fallback
            assert.is_not_nil(sets.Debug)
            assert.equals("default", sets.Debug.Frontend)
        end)

        it("returns nil for empty projects", function()
            local dir = tmpdir()
            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {},
            })

            local sets, err = config_editor.generate_default_config_sets(dir)
            assert.is_nil(sets)
            assert.is_not_nil(err)
        end)

        it("fails when loomworks.json does not exist", function()
            local dir = tmpdir()

            local sets, err = config_editor.generate_default_config_sets(dir)
            assert.is_nil(sets)
            assert.is_not_nil(err)
        end)

        it("handles mixed module types", function()
            local dir = tmpdir()
            vim.fn.mkdir(dir .. "/App", "p")
            write_raw(dir .. "/App/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")
            vim.fn.mkdir(dir .. "/UI", "p")
            write_raw(dir .. "/UI/build-profile.json5", "{}")

            io_mod.write_json(dir .. "/loomworks.json", {
                name = "test",
                projects = {
                    App = { cmake = {} },
                    UI = { ets = {} },
                },
            })

            local sets, err = config_editor.generate_default_config_sets(dir)
            assert.is_nil(err)
            assert.is_not_nil(sets)
            -- cmake has Debug/Release, ets has debug/release → both map
            assert.is_not_nil(sets.Debug)
            assert.is_not_nil(sets.Release)
        end)
    end)
end)
