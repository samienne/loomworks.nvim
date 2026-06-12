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

describe("module detection", function()
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
    -- cmake.detect
    -- -----------------------------------------------------------------
    describe("cmake.detect", function()
        local cmake = require("loomworks.modules.cmake")

        it("returns marker for directory with CMakeLists.txt", function()
            local dir = tmpdir()
            write_raw(dir .. "/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")

            local result = cmake.detect(dir)
            assert.is_not_nil(result)
            assert.equals("CMakeLists.txt", result.marker)
        end)

        it("returns nil for empty directory", function()
            local dir = tmpdir()
            assert.is_nil(cmake.detect(dir))
        end)
    end)

    -- -----------------------------------------------------------------
    -- typescript.detect
    -- -----------------------------------------------------------------
    describe("typescript.detect", function()
        local ts = require("loomworks.modules.typescript")

        it("returns marker for directory with tsconfig.json", function()
            local dir = tmpdir()
            write_raw(dir .. "/tsconfig.json", "{}")

            local result = ts.detect(dir)
            assert.is_not_nil(result)
            assert.equals("tsconfig.json", result.marker)
        end)

        it("returns marker for package.json with typescript dependency", function()
            local dir = tmpdir()
            write_raw(dir .. "/package.json", vim.json.encode({
                dependencies = { typescript = "^5.0.0" },
            }))

            local result = ts.detect(dir)
            assert.is_not_nil(result)
            assert.equals("package.json", result.marker)
        end)

        it("returns marker for package.json with typescript devDependency", function()
            local dir = tmpdir()
            write_raw(dir .. "/package.json", vim.json.encode({
                devDependencies = { typescript = "^5.0.0" },
            }))

            local result = ts.detect(dir)
            assert.is_not_nil(result)
            assert.equals("package.json", result.marker)
        end)

        it("returns nil for package.json without typescript", function()
            local dir = tmpdir()
            write_raw(dir .. "/package.json", vim.json.encode({
                dependencies = { express = "^4.0.0" },
            }))

            assert.is_nil(ts.detect(dir))
        end)

        it("prefers tsconfig.json over package.json", function()
            local dir = tmpdir()
            write_raw(dir .. "/tsconfig.json", "{}")
            write_raw(dir .. "/package.json", vim.json.encode({
                dependencies = { typescript = "^5.0.0" },
            }))

            local result = ts.detect(dir)
            assert.is_not_nil(result)
            assert.equals("tsconfig.json", result.marker)
        end)

        it("returns nil for empty directory", function()
            local dir = tmpdir()
            assert.is_nil(ts.detect(dir))
        end)
    end)

    -- -----------------------------------------------------------------
    -- cmake.map_variant
    -- -----------------------------------------------------------------
    describe("cmake.map_variant", function()
        local cmake = require("loomworks.modules.cmake")

        it("maps debug to Debug (case-insensitive)", function()
            assert.equals("Debug", cmake.map_variant("debug", { "Debug", "Release" }))
        end)

        it("maps release to Release", function()
            assert.equals("Release", cmake.map_variant("release", { "Debug", "Release" }))
        end)

        it("maps release_debug to RelWithDebInfo", function()
            assert.equals("RelWithDebInfo", cmake.map_variant("release_debug", { "Debug", "Release", "RelWithDebInfo" }))
        end)

        it("returns nil for unknown variant type", function()
            assert.is_nil(cmake.map_variant("unknown", { "Debug", "Release" }))
        end)

        it("returns nil when no match found", function()
            assert.is_nil(cmake.map_variant("release_debug", { "Debug", "Release" }))
        end)

        it("returns sole config for any variant (single-config fallback)", function()
            assert.equals("MyPreset", cmake.map_variant("debug", { "MyPreset" }))
            assert.equals("MyPreset", cmake.map_variant("release", { "MyPreset" }))
            assert.equals("MyPreset", cmake.map_variant("release_debug", { "MyPreset" }))
        end)
    end)

    -- -----------------------------------------------------------------
    -- typescript.map_variant
    -- -----------------------------------------------------------------
    describe("typescript.map_variant", function()
        local ts = require("loomworks.modules.typescript")

        it("maps debug to development", function()
            assert.equals("development", ts.map_variant("debug", { "development", "production" }))
        end)

        it("maps release to production", function()
            assert.equals("production", ts.map_variant("release", { "development", "production" }))
        end)

        it("maps debug to default as fallback", function()
            assert.equals("default", ts.map_variant("debug", { "default", "staging" }))
        end)

        it("maps release to default as fallback", function()
            assert.equals("default", ts.map_variant("release", { "default", "staging" }))
        end)

        it("returns nil for release_debug", function()
            assert.is_nil(ts.map_variant("release_debug", { "development", "production" }))
        end)

        it("returns sole config for any variant", function()
            assert.equals("custom", ts.map_variant("debug", { "custom" }))
        end)
    end)

    -- -----------------------------------------------------------------
    -- modules.detect_all_types
    -- -----------------------------------------------------------------
    describe("detect_all_types", function()
        local modules = require("loomworks.modules")

        it("detects single cmake project", function()
            local dir = tmpdir()
            write_raw(dir .. "/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")

            local results = modules.detect_all_types(dir)
            assert.equals(1, #results)
            assert.equals("cmake", results[1].type)
            assert.equals("CMakeLists.txt", results[1].marker)
        end)

        it("detects multiple types on same directory", function()
            local dir = tmpdir()
            write_raw(dir .. "/CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)")
            write_raw(dir .. "/tsconfig.json", "{}")

            local results = modules.detect_all_types(dir)
            assert.equals(2, #results)

            -- Results are sorted by module ID (cmake < typescript)
            local types = {}
            for _, r in ipairs(results) do
                types[r.type] = r.marker
            end
            assert.equals("CMakeLists.txt", types.cmake)
            assert.equals("tsconfig.json", types.typescript)
        end)

        it("returns empty list for directory with no markers", function()
            local dir = tmpdir()
            local results = modules.detect_all_types(dir)
            assert.equals(0, #results)
        end)
    end)
end)
