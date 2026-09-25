-- Compiler-cache wording (v0.1.30 real-project feedback):
--   * a pervasive finding that hits EVERY target but not every unit says
--     "every target, nearly every unit" — only the unit count is "nearly";
--   * the failed-build closing line matches the scan's severity ("will fail");
--   * health's affirmative "Compiler cache: using <tool>" is qualified when the
--     scan recorded compiles that launcher will fail.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cc = require("loomworks.compiler_cache")
local suggestions = require("loomworks.suggestions")

--- `n` targets of `per` /Zi units each (error severity).
local function record(n, per, total_units, total_targets)
    local findings = {}
    for i = 1, n do
        findings[#findings + 1] = { severity = "error", flag = "/Zi", group = "t" .. i,
            units = per, sample = { "C:/src/t" .. i .. "/a.c" } }
    end
    return { tool = "sccache", scanned = true, findings = findings,
        totals = { units = total_units, targets = total_targets } }
end

describe("pervasive finding scope wording", function()
    it("every target but not every unit → `every target, nearly every unit`", function()
        local lines = cc.compat_group_lines(record(77, 10, 800, 77))
        assert.equals(1, #lines)
        assert.matches("every target, nearly every unit (770 of 800 units) compiles with /Zi",
            lines[1], 1, true)
        assert.is_nil(lines[1]:find("nearly every target", 1, true))
    end)

    it("every unit of every target → `every target (N units)`", function()
        assert.matches("^every target %(770 units%)", cc.compat_group_lines(record(77, 10, 770, 77))[1])
    end)

    it("not every target → `nearly every target (… , T of M targets)`", function()
        assert.matches("nearly every target (190 of 200 units, 19 of 21 targets)",
            cc.compat_group_lines(record(19, 10, 200, 21))[1], 1, true)
    end)
end)

describe("failed-build closing line", function()
    it("says the launcher will fail those compiles", function()
        local hint = cc.compat_failure_hint(record(2, 10, 500, 40))
        assert.matches("which sccache will fail", hint, 1, true)
        assert.is_nil(hint:find("cannot cache", 1, true))
    end)
end)

describe("health: `using <tool>` next to a failing finding", function()
    local cpp = require("loomworks.cpp_compilers")
    local orig_lookup
    before_each(function()
        orig_lookup = cpp.lookup_path
        cpp.lookup_path = function(name) return name == "sccache" and "/bin/sccache" or nil end
    end)
    after_each(function() cpp.lookup_path = orig_lookup end)

    local function ws_with(compat)
        local unit = { _project = { key = "App" }, _configuration = { name = "Debug" },
            module_info = { cache_compat = compat } }
        local profile = {
            key = "P",
            compiler_cache_status = function()
                return { policy = "sccache", present = true, tool = "sccache", applicable = true }
            end,
            projects = function() return { { _config_unit = unit } } end,
        }
        return {
            _projects = { { key = "App", _module = { caches_cpp = function() return true end },
                _configurations = {} } },
            _active_profile = profile,
            _profiles = { profile },
        }
    end

    it("qualifies the affirmation with the failing compile count", function()
        local out = suggestions.compiler_cache_provider(ws_with(record(2, 10, 500, 40)))
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.equals("Compiler cache: using sccache — but it will fail 20 compiles (lw help cache)",
            out[1].title)
    end)

    it("stays a plain affirmation without an error finding", function()
        local out = suggestions.compiler_cache_provider(ws_with({ tool = "sccache", scanned = true, findings = {} }))
        assert.equals("Compiler cache: using sccache", out[1].title)
    end)
end)
