local cache = require("loomworks.cache")

describe("cache", function()
    describe("default", function()
        it("returns table with version 8 and empty build_dirs", function()
            local d = cache.default()
            assert.equals(8, d._meta.version)
            assert.are.same({}, d.build_dirs)
        end)
    end)

    describe("parse", function()
        it("parses valid cache.json", function()
            local json = vim.json.encode({
                _meta = { version = 8, loomworks_hash = "abc", cached_at = "2025-01-01" },
                build_dirs = {
                    ["build/App/Debug"] = {
                        project_key = "App",
                        type = "cmake",
                        variant = "Debug",
                        state = "built",
                        last_built = "2025-01-01",
                    },
                },
            })
            local result = cache.parse(json)
            assert.equals(8, result._meta.version)
            assert.equals("built", result.build_dirs["build/App/Debug"].state)
        end)

        it("returns no version mismatch on valid parse", function()
            local json = vim.json.encode({
                _meta = { version = 8, loomworks_hash = "abc", cached_at = "2025-01-01" },
                build_dirs = {},
            })
            local _, mismatch = cache.parse(json)
            assert.is_false(mismatch)
        end)

        it("returns defaults on invalid JSON without version mismatch", function()
            local result, mismatch = cache.parse("broken {{{")
            assert.equals(8, result._meta.version)
            assert.are.same({}, result.build_dirs)
            assert.is_false(mismatch)
        end)

        it("returns defaults and version mismatch on wrong version", function()
            local json = vim.json.encode({
                _meta = { version = 999 },
                build_dirs = {},
            })
            local result, mismatch = cache.parse(json)
            assert.are.same({}, result.build_dirs)
            assert.is_true(mismatch)
        end)

        it("returns version mismatch on old version", function()
            local json = vim.json.encode({
                _meta = { version = 6 },
                configurations = {},
            })
            local _, mismatch = cache.parse(json)
            assert.is_true(mismatch)
        end)

        it("returns version mismatch on v3", function()
            local json = vim.json.encode({
                _meta = { version = 3 },
                projects = {},
            })
            local result, mismatch = cache.parse(json)
            assert.are.same({}, result.build_dirs)
            assert.is_true(mismatch)
        end)

        it("ensures build_dirs field exists", function()
            local json = vim.json.encode({
                _meta = { version = 8 },
            })
            local result = cache.parse(json)
            assert.are.same({}, result.build_dirs)
        end)

        it("migrates v7 cache by renaming cmake to module_info", function()
            local json = vim.json.encode({
                _meta = { version = 7 },
                build_dirs = {
                    ["build/App/Debug"] = {
                        project_key = "App",
                        type = "cmake",
                        variant = "Debug",
                        state = "built",
                        cmake = { generator = "Ninja", compiler = "gcc" },
                    },
                },
            })
            local result, mismatch = cache.parse(json)
            assert.is_false(mismatch, "v7 cache should migrate without triggering mismatch")
            assert.equals(8, result._meta.version)
            local entry = result.build_dirs["build/App/Debug"]
            assert.is_nil(entry.cmake, "old cmake field should be cleared")
            assert.is_not_nil(entry.module_info)
            assert.equals("Ninja", entry.module_info.generator)
            assert.equals("gcc", entry.module_info.compiler)
        end)

        it("v7 migration leaves entry unchanged when no cmake field", function()
            local json = vim.json.encode({
                _meta = { version = 7 },
                build_dirs = {
                    ["build/App/Debug"] = {
                        project_key = "App",
                        type = "cmake",
                        variant = "Debug",
                        state = "built",
                    },
                },
            })
            local result = cache.parse(json)
            assert.equals(8, result._meta.version)
            assert.is_nil(result.build_dirs["build/App/Debug"].module_info)
        end)

        it("v7 migration prefers existing module_info over cmake if both present", function()
            local json = vim.json.encode({
                _meta = { version = 7 },
                build_dirs = {
                    ["build/App/Debug"] = {
                        project_key = "App",
                        type = "cmake",
                        variant = "Debug",
                        cmake = { generator = "OldGen" },
                        module_info = { generator = "NewGen" },
                    },
                },
            })
            local result = cache.parse(json)
            assert.equals("NewGen", result.build_dirs["build/App/Debug"].module_info.generator)
            assert.is_nil(result.build_dirs["build/App/Debug"].cmake)
        end)
    end)

    describe("config_cache_key", function()
        it("combines project_key and config_key with slash", function()
            assert.equals("App/Debug", cache.config_cache_key("App", "Debug"))
        end)

        it("works with tool-qualified config keys", function()
            assert.equals("App/Debug:ninja-gcc-12", cache.config_cache_key("App", "Debug:ninja-gcc-12"))
        end)
    end)

    describe("relative_build_dir", function()
        it("strips root/.nvim/ prefix", function()
            assert.equals("build/App/Debug",
                cache.relative_build_dir("/workspace/.nvim/build/App/Debug", "/workspace"))
        end)

        it("returns path as-is for external dirs", function()
            assert.equals("/external/build",
                cache.relative_build_dir("/external/build", "/workspace"))
        end)
    end)

    describe("absolute_build_dir", function()
        it("prepends root/.nvim/ to relative path", function()
            assert.equals("/workspace/.nvim/build/App/Debug",
                cache.absolute_build_dir("build/App/Debug", "/workspace"))
        end)

        it("returns absolute path as-is", function()
            assert.equals("/external/build",
                cache.absolute_build_dir("/external/build", "/workspace"))
        end)

        it("returns Windows absolute path as-is", function()
            assert.equals("C:/builds/App",
                cache.absolute_build_dir("C:/builds/App", "/workspace"))
        end)
    end)

    describe("compute_hash", function()
        it("returns a 12-character string", function()
            local hash = cache.compute_hash('{"projects": {}}')
            assert.equals(12, #hash)
        end)

        it("returns different hashes for different content", function()
            local h1 = cache.compute_hash('{"projects": {"A": {}}}')
            local h2 = cache.compute_hash('{"projects": {"B": {}}}')
            assert.are_not.equals(h1, h2)
        end)

        it("returns same hash for same content", function()
            local content = '{"projects": {}}'
            assert.equals(cache.compute_hash(content), cache.compute_hash(content))
        end)
    end)

    describe("validate_consistency", function()
        it("passes for cache without profiles", function()
            local ok = cache.validate_consistency({ build_dirs = {} })
            assert.is_true(ok)
        end)

        it("passes when all build_dirs entries have required fields", function()
            local data = {
                build_dirs = {
                    ["build/App/Debug"] = { project_key = "App", variant = "Debug" },
                },
            }
            local ok = cache.validate_consistency(data)
            assert.is_true(ok)
        end)

        it("fails when build_dir entry is missing project_key", function()
            local data = {
                build_dirs = {
                    ["build/App/Debug"] = { variant = "Debug" },
                },
            }
            local ok, err = cache.validate_consistency(data)
            assert.is_false(ok)
            assert.matches("missing project_key", err)
        end)

        it("fails when build_dir entry is missing variant", function()
            local data = {
                build_dirs = {
                    ["build/App/Debug"] = { project_key = "App" },
                },
            }
            local ok, err = cache.validate_consistency(data)
            assert.is_false(ok)
            assert.matches("missing variant", err)
        end)

        it("ignores profiles section in cache (profiles are runtime-only)", function()
            local data = {
                build_dirs = {},
                profiles = {
                    ["debug"] = { configurations = { "build/App/Debug" } },
                },
            }
            local ok = cache.validate_consistency(data)
            assert.is_true(ok)
        end)
    end)

    describe("filepath", function()
        it("returns path under .nvim", function()
            local p = cache.filepath("/workspace")
            assert.equals("/workspace/.nvim/loomworks.cache.json", p)
        end)
    end)
end)
