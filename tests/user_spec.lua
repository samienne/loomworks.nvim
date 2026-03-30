local user = require("loomworks.user")

describe("user", function()
    describe("default", function()
        it("returns table with version meta", function()
            local d = user.default()
            assert.is_not_nil(d._meta)
            assert.equals(2, d._meta.version)
        end)
    end)

    describe("parse", function()
        it("parses valid v2 user.json", function()
            local json = vim.json.encode({
                _meta = { version = 2 },
                active_profile = "debug:ninja-gcc-14",
            })
            local result = user.parse(json)
            assert.equals("debug:ninja-gcc-14", result.active_profile)
        end)

        it("migrates v1 user.json to v2", function()
            local json = vim.json.encode({
                _meta = { version = 1 },
                active_profile = "debug:ninja-gcc-14",
            })
            local result, mismatch = user.parse(json)
            assert.is_false(mismatch)
            assert.equals(2, result._meta.version)
            assert.equals("debug:ninja-gcc-14", result.active_profile)
        end)

        it("returns defaults on invalid JSON", function()
            local result = user.parse("not json")
            assert.equals(2, result._meta.version)
            assert.is_nil(result.active_profile)
        end)

        it("returns defaults on wrong version", function()
            local json = vim.json.encode({
                _meta = { version = 999 },
                active_profile = "should-be-ignored",
            })
            local result = user.parse(json)
            assert.equals(2, result._meta.version)
            assert.is_nil(result.active_profile)
        end)

        it("returns defaults when _meta is missing", function()
            local json = vim.json.encode({ active_profile = "test" })
            local result = user.parse(json)
            assert.is_nil(result.active_profile)
        end)

        it("returns defaults on empty string", function()
            local result = user.parse("")
            assert.equals(2, result._meta.version)
        end)

        it("preserves projects and configuration_sets fields from v1", function()
            local json = vim.json.encode({
                _meta = { version = 1 },
                active_profile = "debug",
                projects = {
                    MyLib = { cmake = {} },
                },
                configuration_sets = {
                    Debug = { MyLib = "Debug" },
                },
            })
            local result = user.parse(json)
            assert.equals("debug", result.active_profile)
            assert.is_not_nil(result.projects)
            assert.is_not_nil(result.projects.MyLib)
            assert.is_not_nil(result.configuration_sets)
            assert.equals("Debug", result.configuration_sets.Debug.MyLib)
        end)

        it("preserves pinned_profiles from v2", function()
            local json = vim.json.encode({
                _meta = { version = 2 },
                active_profile = "debug",
                pinned_profiles = {
                    ["App/Debug"] = { mappings = { App = "Debug" } },
                },
            })
            local result = user.parse(json)
            assert.equals("debug", result.active_profile)
            assert.is_not_nil(result.pinned_profiles)
            assert.is_not_nil(result.pinned_profiles["App/Debug"])
            assert.same({ App = "Debug" }, result.pinned_profiles["App/Debug"].mappings)
        end)
    end)

    describe("filepath", function()
        it("returns path under .nvim", function()
            local p = user.filepath("/workspace")
            assert.equals("/workspace/.nvim/loomworks.user.json", p)
        end)
    end)
end)
