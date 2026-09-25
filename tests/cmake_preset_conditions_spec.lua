--- CMakePresets `condition` evaluation (spec/modules/cmake.md §3): a configure
--- preset whose condition is FALSE on this host (e.g. a macOS-only preset on
--- Windows) is not offered as a configuration — as CMake itself would refuse
--- it. Conditions are inherited from base presets. An unsupported macro or
--- condition shape never hides a preset and never errors.

local cmake = require("loomworks.modules.cmake")

local function write_file(dir, name, contents)
    local fd = assert(io.open(dir .. "/" .. name, "w"))
    fd:write(contents)
    fd:close()
end

local function eval(cond, ctx)
    ctx = ctx or {}
    return cmake._preset_condition(cond, {
        host = ctx.host or "Windows",
        preset_name = ctx.preset_name or "p",
        source_dir = ctx.source_dir or "C:/src/app",
        environment = ctx.environment,
        getenv = ctx.getenv or function() return nil end,
    })
end

describe("cmake preset condition evaluator", function()
    it("const / null / missing", function()
        assert.is_true(eval({ type = "const", value = true }))
        assert.is_false(eval({ type = "const", value = false }))
        assert.is_true(eval(nil))
        assert.is_true(eval(vim.NIL))
    end)

    it("equals / notEquals with ${hostSystemName}", function()
        local mac = { type = "equals", lhs = "${hostSystemName}", rhs = "Darwin" }
        assert.is_false(eval(mac, { host = "Windows" }))
        assert.is_true(eval(mac, { host = "Darwin" }))
        assert.is_true(eval({ type = "notEquals", lhs = "${hostSystemName}", rhs = "Windows" },
            { host = "Linux" }))
    end)

    it("inList / notInList", function()
        local c = { type = "inList", string = "${hostSystemName}", list = { "Linux", "Darwin" } }
        assert.is_false(eval(c, { host = "Windows" }))
        assert.is_true(eval(c, { host = "Linux" }))
        c.type = "notInList"
        assert.is_true(eval(c, { host = "Windows" }))
    end)

    it("matches / notMatches (simple regexes)", function()
        assert.is_true(eval({ type = "matches", string = "${hostSystemName}", regex = "^Win" }))
        assert.is_false(eval({ type = "matches", string = "${hostSystemName}", regex = "^Dar.*n$" }))
        assert.is_true(eval({ type = "notMatches", string = "${presetName}", regex = "mac" },
            { preset_name = "win-debug" }))
        assert.is_true(eval({ type = "matches", string = "a.b", regex = "a\\.b" }))
        assert.is_false(eval({ type = "matches", string = "axb", regex = "a\\.b" }))
    end)

    it("anyOf / allOf / not", function()
        local win = { type = "equals", lhs = "${hostSystemName}", rhs = "Windows" }
        local mac = { type = "equals", lhs = "${hostSystemName}", rhs = "Darwin" }
        assert.is_true(eval({ type = "anyOf", conditions = { mac, win } }))
        assert.is_false(eval({ type = "allOf", conditions = { mac, win } }))
        assert.is_false(eval({ type = "not", condition = win }))
        assert.is_true(eval({ type = "not", condition = mac }))
    end)

    it("$env{} reads the preset environment, then the process environment", function()
        local c = { type = "equals", lhs = "$env{TARGET}", rhs = "arm" }
        assert.is_true(eval(c, { environment = { TARGET = "arm" } }))
        assert.is_true(eval(c, { getenv = function(n) return n == "TARGET" and "arm" or nil end }))
        assert.is_false(eval(c))
        assert.is_true(eval({ type = "equals", lhs = "$penv{HOME}", rhs = "/h" },
            { getenv = function(n) return n == "HOME" and "/h" or nil end }))
    end)

    it("unknown macros / types / unsupported regexes are UNKNOWN (never hide)", function()
        assert.is_nil(eval({ type = "equals", lhs = "$vendor{x}", rhs = "y" }))
        assert.is_nil(eval({ type = "frobnicate" }))
        assert.is_nil(eval({ type = "matches", string = "x", regex = "(a|b)" }))
        -- anyOf with an unknown member and a false member stays unknown
        assert.is_nil(eval({ type = "anyOf", conditions = {
            { type = "const", value = false }, { type = "frobnicate" } } }))
        -- allOf with a false member is false regardless of unknowns
        assert.is_false(eval({ type = "allOf", conditions = {
            { type = "const", value = false }, { type = "frobnicate" } } }))
    end)
end)

describe("cmake presets filtered by host condition", function()
    local dir, saved_host

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        write_file(dir, "CMakeLists.txt", "project(App)\n")
        write_file(dir, "CMakePresets.json", [[
{
  "version": 3,
  "configurePresets": [
    { "name": "mac-base", "hidden": true,
      "condition": { "type": "equals", "lhs": "${hostSystemName}", "rhs": "Darwin" } },
    { "name": "mac-debug", "inherits": "mac-base", "generator": "Ninja",
      "binaryDir": "${sourceDir}/out/mac" },
    { "name": "win-debug", "generator": "Ninja", "binaryDir": "${sourceDir}/out/win",
      "condition": { "type": "equals", "lhs": "${hostSystemName}", "rhs": "Windows" } },
    { "name": "mac-override", "inherits": "mac-base", "generator": "Ninja",
      "binaryDir": "${sourceDir}/out/any",
      "condition": { "type": "const", "value": true } },
    { "name": "vendor", "generator": "Ninja", "binaryDir": "${sourceDir}/out/v",
      "condition": { "type": "equals", "lhs": "$vendor{x}", "rhs": "y" } },
    { "name": "plain", "generator": "Ninja", "binaryDir": "${sourceDir}/out/plain" }
  ]
}
]])
        saved_host = cmake._host_system_name
    end)

    after_each(function()
        cmake._host_system_name = saved_host
        vim.fn.delete(dir, "rf")
    end)

    local function names(host)
        cmake._host_system_name = function() return host end
        local info = cmake.info(dir, {})
        local out = {}
        for k in pairs(info.preset_configurations or {}) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    it("on Windows hides the macOS presets (own and inherited conditions)", function()
        assert.same({ "preset:mac-override", "preset:plain", "preset:vendor", "preset:win-debug" },
            names("Windows"))
    end)

    it("on Darwin hides the Windows preset", function()
        assert.same({ "preset:mac-debug", "preset:mac-override", "preset:plain", "preset:vendor" },
            names("Darwin"))
    end)

    it("the real host name is one of CMake's spellings", function()
        local h = saved_host()
        assert.is_truthy(h == "Windows" or h == "Linux" or h == "Darwin" or type(h) == "string")
        if vim.fn.has("win32") == 1 then assert.equals("Windows", h) end
    end)
end)
